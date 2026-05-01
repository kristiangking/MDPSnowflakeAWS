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
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

import boto3
import yaml

ANALYTICS_DB = "WHITEGOODS_ANALYTICS"
MART_SCHEMA = "MARTS"
SSM_BUCKET_PARAM = "/mdp/data_products/whitegoods_inventory/raw_bucket_name"
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
    connection_string = build_connection_string(creds)
    expectations_dir = Path(args.gx_dir) / "expectations"

    print(f"  Target       : {ANALYTICS_DB}.{MART_SCHEMA}")
    print(f"  Results sink : s3://{bucket}/{S3_PREFIX}/")

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

    print("Done.")


if __name__ == "__main__":
    main()
