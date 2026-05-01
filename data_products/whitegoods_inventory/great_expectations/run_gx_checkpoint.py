#!/usr/bin/env python3
"""
Great Expectations checkpoint runner for whitegoods_inventory.

Connects to Snowflake via GX Fluent API (0.18.x), runs expectations against
WHITEGOODS_ANALYTICS.MARTS tables, and writes flat JSON results to S3 for
ingestion into WHITEGOODS_RAW.GX.VALIDATIONS via Snowpipe.

Usage (called by Airflow BashOperator):
    python run_gx_checkpoint.py \
        --profiles-dir /home/airflow/.dbt \
        --gx-dir /opt/airflow/great_expectations/whitegoods_inventory \
        --region ap-southeast-2

Exit codes:
    0 — always (validation failures are surfaced via S3 → Snowpipe → dashboard,
         not via process exit code). Pass --fail-on-error to override this
         behaviour if you want the Airflow task itself to fail on failures.
"""

import argparse
import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

import boto3
import requests
import yaml

ANALYTICS_DB = "WHITEGOODS_ANALYTICS"
MART_SCHEMA = "MARTS"
SSM_BUCKET_PARAM = "/mdp/data_products/whitegoods_inventory/raw_bucket_name"
SSM_DATAHUB_GMS_PARAM = "/mdp/platform/datahub_gms_url"
S3_PREFIX = "great_expectations/results"


# ── Credential helpers ─────────────────────────────────────────────────────────

def get_snowflake_creds(profiles_dir: str) -> dict:
    """Read Snowflake credentials from the dbt profiles.yml."""
    path = Path(profiles_dir) / "profiles.yml"
    with open(path) as f:
        profiles = yaml.safe_load(f)
    return profiles["whitegoods_inventory"]["outputs"]["dev"]


def get_raw_bucket(region: str) -> str:
    """Read the raw S3 bucket name from SSM Parameter Store."""
    ssm = boto3.client("ssm", region_name=region)
    return ssm.get_parameter(Name=SSM_BUCKET_PARAM)["Parameter"]["Value"]


def get_datahub_gms_url(region: str) -> str | None:
    """Read the DataHub GMS URL from SSM. Returns None if not found."""
    ssm = boto3.client("ssm", region_name=region)
    try:
        return ssm.get_parameter(Name=SSM_DATAHUB_GMS_PARAM)["Parameter"]["Value"]
    except ssm.exceptions.ParameterNotFound:
        return None


def build_connection_string(creds: dict) -> str:
    """Build a Snowflake SQLAlchemy connection string from dbt credentials."""
    account = creds["account"]
    return (
        f"snowflake://{creds['user']}:{creds['password']}"
        f"@{account}/{ANALYTICS_DB}/{MART_SCHEMA}"
        f"?warehouse={creds['warehouse']}&role={creds['role']}"
    )


# ── GX validation ──────────────────────────────────────────────────────────────

def run_validations(connection_string: str, expectations_dir: Path) -> tuple[list, str]:
    """
    Run GX expectations (Fluent API, 0.18.x) against all expectation suites
    found in expectations_dir. Returns (flat_results, run_id).

    GX pushes SQL down to Snowflake — no data leaves the warehouse.
    """
    import great_expectations as gx
    from great_expectations.data_context import EphemeralDataContext
    from great_expectations.data_context.types.base import (
        DataContextConfig,
        InMemoryStoreBackendDefaults,
    )

    config = DataContextConfig(store_backend_defaults=InMemoryStoreBackendDefaults())
    context = EphemeralDataContext(project_config=config)

    datasource = context.sources.add_snowflake(
        name="snowflake_whitegoods",
        connection_string=connection_string,
    )

    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    run_time = datetime.now(timezone.utc).isoformat()
    all_results = []

    for suite_file in sorted(expectations_dir.glob("*.json")):
        with open(suite_file) as f:
            suite_cfg = json.load(f)

        suite_name = suite_cfg["expectation_suite_name"]
        table_name = suite_name.upper()  # mart_inventory_summary → MART_INVENTORY_SUMMARY

        print(f"  Validating {ANALYTICS_DB}.{MART_SCHEMA}.{table_name}...")

        # Register table asset with datasource
        table_asset = datasource.add_table_asset(
            name=suite_name,
            table_name=table_name,
            schema_name=MART_SCHEMA,
        )
        batch_request = table_asset.build_batch_request()

        # Build expectation suite in context
        suite = context.add_expectation_suite(suite_name)
        validator = context.get_validator(
            batch_request=batch_request,
            expectation_suite_name=suite_name,
        )

        # Register each expectation on the validator
        for exp in suite_cfg["expectations"]:
            exp_type = exp["expectation_type"]
            kwargs = exp.get("kwargs", {})
            getattr(validator, exp_type)(**kwargs, result_format="BASIC")

        validation_result = validator.validate(result_format="BASIC")

        # Flatten individual expectation results to one dict per check
        for er in validation_result.results:
            ec = er.expectation_config
            res = er.result

            observed = res.get("observed_value")
            all_results.append({
                "run_id": run_id,
                "checkpoint_name": "whitegoods_checkpoint",
                "suite_name": suite_name,
                "data_asset_name": f"{ANALYTICS_DB}.{MART_SCHEMA}.{table_name}",
                "expectation_type": ec.expectation_type,
                "column_name": ec.kwargs.get("column"),
                "success": bool(er.success),
                "observed_value": str(observed) if observed is not None else None,
                "unexpected_count": int(res.get("unexpected_count") or 0),
                "unexpected_percent": float(res.get("unexpected_percent") or 0.0),
                "run_time": run_time,
            })

    return all_results, run_id


# ── S3 result sink ─────────────────────────────────────────────────────────────

def write_to_s3(results: list, run_id: str, bucket: str, region: str) -> str:
    """
    Write flat JSON array to S3 at great_expectations/results/<run_id>.json.
    Snowpipe picks this up and loads into WHITEGOODS_RAW.GX.VALIDATIONS.
    The file is a JSON array (strip_outer_array=true in the pipe's file format).
    """
    s3 = boto3.client("s3", region_name=region)
    key = f"{S3_PREFIX}/{run_id}.json"
    s3.put_object(
        Bucket=bucket,
        Key=key,
        Body=json.dumps(results),
        ContentType="application/json",
    )
    return f"s3://{bucket}/{key}"


# ── DataHub assertion emission ─────────────────────────────────────────────────

# Maps GX expectation types to DataHub DatasetAssertionStdOperator enum values.
# Used to satisfy the required `operator` field on assertionInfo.datasetAssertion.
GX_OPERATOR_MAP: dict[str, str] = {
    "expect_column_values_to_not_be_null":       "NOT_NULL",
    "expect_column_values_to_be_null":            "IS_NULL",
    "expect_column_values_to_be_unique":          "NOT_EQUAL_TO",
    "expect_column_values_to_be_in_set":          "IN",
    "expect_column_values_to_not_be_in_set":      "NOT_IN",
    "expect_column_values_to_be_between":         "BETWEEN",
    "expect_column_values_to_match_regex":        "REGEX_MATCH",
    "expect_column_values_to_match_like_pattern": "REGEX_MATCH",
    "expect_table_row_count_to_be_between":       "BETWEEN",
    "expect_table_row_count_to_equal":            "EQUAL_TO",
    "expect_column_mean_to_be_between":           "BETWEEN",
    "expect_column_median_to_be_between":         "BETWEEN",
    "expect_column_stdev_to_be_between":          "BETWEEN",
    "expect_column_sum_to_be_between":            "BETWEEN",
    "expect_column_min_to_be_between":            "BETWEEN",
    "expect_column_max_to_be_between":            "BETWEEN",
}


def _assertion_urn(suite_name: str, expectation_type: str, column_name: str | None) -> str:
    """Stable, deterministic assertion URN derived from the check identity."""
    key = f"gx:{suite_name}:{expectation_type}:{column_name or '__table__'}"
    return f"urn:li:assertion:{hashlib.md5(key.encode()).hexdigest()}"


def _dataset_urn(data_asset_name: str) -> str:
    """
    Build a Snowflake dataset URN from the fully-qualified table name.
    DataHub stores Snowflake datasets in lowercase: db.schema.table
    e.g. WHITEGOODS_ANALYTICS.MARTS.MART_INVENTORY_SUMMARY
      → urn:li:dataset:(urn:li:dataPlatform:snowflake,whitegoods_analytics.marts.mart_inventory_summary,PROD)
    """
    return (
        f"urn:li:dataset:(urn:li:dataPlatform:snowflake,"
        f"{data_asset_name.lower()},PROD)"
    )


def _ingest_proposal(
    gms_url: str,
    entity_urn: str,
    entity_type: str,
    aspect_name: str,
    aspect_value: dict,
) -> None:
    """
    Emit a single MCP via the DataHub legacy /aspects?action=ingestProposal endpoint.
    This endpoint is stable across DataHub versions and gives clear validation errors.
    """
    payload = {
        "proposal": {
            "entityType": entity_type,
            "entityUrn": entity_urn,
            "aspectName": aspect_name,
            "changeType": "UPSERT",
            "aspect": {
                "value": json.dumps(aspect_value),
                "contentType": "application/json",
            },
        }
    }
    resp = requests.post(
        f"{gms_url}/aspects?action=ingestProposal",
        json=payload,
        headers={"Content-Type": "application/json"},
        timeout=10,
    )
    if not resp.ok:
        raise requests.HTTPError(
            f"{resp.status_code} {resp.reason} — {resp.text[:400]}"
        )


def emit_datahub_assertions(results: list, run_id: str, gms_url: str) -> None:
    """
    Emit GX validation results as DataHub assertions via the legacy ingestProposal API.

    For each expectation result we emit two MCPs:
      1. assertionInfo      — defines the assertion (upserted idempotently on each run)
      2. assertionRunEvent  — the PASS/FAIL result for this specific run

    Assertions appear on the dataset page in DataHub under the
    "Quality" tab with a PASS/FAIL badge per expectation.
    """
    run_ts_ms = int(datetime.now(timezone.utc).timestamp() * 1000)
    emitted = 0
    errors = 0

    for result in results:
        suite_name       = result["suite_name"]
        expectation_type = result["expectation_type"]
        column_name      = result.get("column_name")
        data_asset_name  = result["data_asset_name"]
        success          = result["success"]

        assertion_urn = _assertion_urn(suite_name, expectation_type, column_name)
        dataset_urn   = _dataset_urn(data_asset_name)

        # ── 1. assertionInfo (what this assertion checks) ──────────────────────
        scope    = "DATASET_COLUMN" if column_name else "DATASET_ROWS"
        operator = GX_OPERATOR_MAP.get(expectation_type, "BETWEEN")  # safe default

        dataset_assertion: dict = {
            "dataset":          dataset_urn,
            "scope":            scope,
            "operator":         operator,
            "nativeType":       expectation_type,
            "nativeParameters": {"column": column_name} if column_name else {},
        }
        if column_name:
            dataset_assertion["fields"] = [
                f"urn:li:schemaField:({dataset_urn},{column_name.lower()})"
            ]

        assertion_info = {
            "type": "DATASET",
            "datasetAssertion": dataset_assertion,
            "customProperties": {
                "suite":           suite_name,
                "expectationType": expectation_type,
                "platform":        "great_expectations",
            },
        }

        # ── 2. assertionRunEvent (this run's pass/fail) ────────────────────────
        native_results: dict = {}
        if result.get("unexpected_count") is not None:
            native_results["unexpected_count"]  = str(result["unexpected_count"])
            native_results["unexpected_percent"] = str(result["unexpected_percent"])
        if result.get("observed_value") is not None:
            native_results["observed_value"] = str(result["observed_value"])

        run_event = {
            "timestampMillis": run_ts_ms,
            "assertionUrn":    assertion_urn,   # required by DataHub v1.5+
            "asserteeUrn":     dataset_urn,
            "runId":           run_id,
            "status":          "COMPLETE",
            "result": {
                "type":          "SUCCESS" if success else "FAILURE",
                "nativeResults": native_results,
            },
        }

        try:
            _ingest_proposal(gms_url, assertion_urn, "assertion", "assertionInfo",    assertion_info)
            _ingest_proposal(gms_url, assertion_urn, "assertion", "assertionRunEvent", run_event)
            emitted += 1
        except Exception as exc:
            print(f"  WARN: failed to emit assertion for {suite_name}/{expectation_type}: {exc}")
            errors += 1

    status = f"{emitted} emitted" + (f", {errors} errors" if errors else "")
    print(f"  DataHub assertions: {status}")


# ── Entry point ────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Run GX validations for whitegoods_inventory and write results to S3."
    )
    parser.add_argument(
        "--profiles-dir",
        default="/home/airflow/.dbt",
        help="Path to the directory containing dbt profiles.yml",
    )
    parser.add_argument(
        "--gx-dir",
        default="/opt/airflow/great_expectations/whitegoods_inventory",
        help="Path to the GX project directory (contains expectations/)",
    )
    parser.add_argument(
        "--region",
        default="ap-southeast-2",
        help="AWS region for SSM and S3",
    )
    parser.add_argument(
        "--fail-on-error",
        action="store_true",
        default=False,
        help=(
            "Exit with code 1 if any expectations fail. "
            "Default is False — failures are surfaced via the GX dashboard, "
            "not by failing the Airflow task."
        ),
    )
    args = parser.parse_args()

    print("Great Expectations checkpoint: whitegoods_inventory")
    print(f"  Profiles dir : {args.profiles_dir}")
    print(f"  GX dir       : {args.gx_dir}")

    creds = get_snowflake_creds(args.profiles_dir)
    bucket = get_raw_bucket(args.region)
    gms_url = get_datahub_gms_url(args.region)
    connection_string = build_connection_string(creds)
    expectations_dir = Path(args.gx_dir) / "expectations"

    print(f"  Target       : {ANALYTICS_DB}.{MART_SCHEMA}")
    print(f"  Results sink : s3://{bucket}/{S3_PREFIX}/")
    print(f"  DataHub GMS  : {gms_url or 'not configured — assertions skipped'}")

    results, run_id = run_validations(connection_string, expectations_dir)
    s3_path = write_to_s3(results, run_id, bucket, args.region)

    # Summary
    total = len(results)
    failures = [r for r in results if not r["success"]]
    passed = total - len(failures)

    print(f"\nRun ID : {run_id}")
    print(f"Results: {passed}/{total} passed — written to {s3_path}")

    if failures:
        print("\nFailed expectations:")
        for f in failures:
            col = f"column={f['column_name']}" if f["column_name"] else "table-level"
            print(
                f"  FAIL [{f['suite_name']}] "
                f"{f['expectation_type']}({col}) — "
                f"{f['unexpected_count']} unexpected rows "
                f"({f['unexpected_percent']:.1f}%)"
            )
        if args.fail_on_error:
            sys.exit(1)

    # Emit assertions to DataHub if GMS URL is available
    if gms_url:
        print("\nEmitting assertions to DataHub...")
        emit_datahub_assertions(results, run_id, gms_url)

    print("Done.")


if __name__ == "__main__":
    main()
