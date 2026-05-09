#!/usr/bin/env python3
"""
Generate a sample Iceberg table for the suppliers dataset, registered directly
in the AWS Glue Data Catalog so Athena can query it immediately.

PyIceberg writes the Parquet data files and Iceberg metadata files directly to
S3, and registers the table in Glue in the same operation — no separate
crawler or DDL step required.

S3 location:  s3://<raw-bucket>/iceberg/suppliers/
Glue database: whitegoods
Glue table:    suppliers

Requirements (install once):
  pip install "pyiceberg[pyarrow,s3fs,glue]" boto3

Usage:
  python generate_iceberg_suppliers.py --region ap-southeast-2

The raw bucket name is read from SSM automatically.
"""

import argparse

import boto3
import pyarrow as pa
from pyiceberg.catalog import load_catalog
from pyiceberg.schema import Schema
from pyiceberg.types import (
    IntegerType,
    NestedField,
    StringType,
)

SSM_PARAM  = "/mdp/data_products/whitegoods_inventory/raw_bucket_name"
NAMESPACE  = "whitegoods"
TABLE_NAME = "suppliers"

SUPPLIERS_DATA = {
    "supplier_id":    ["SUP-001",                      "SUP-002",                 "SUP-003"],
    "name":           ["ApplianceCo AU",                "Pacific Whitegoods",      "Hometech Direct"],
    "lead_time_days": [14,                              21,                        10],
    "contact_email":  ["orders@applianceco.com.au",     "supply@pacificwg.com.au", "purchasing@hometechdirect.com.au"],
    "payment_terms":  ["NET30",                         "NET45",                   "NET30"],
}


def get_raw_bucket(region: str) -> str:
    ssm = boto3.client("ssm", region_name=region)
    return ssm.get_parameter(Name=SSM_PARAM)["Parameter"]["Value"]


def main():
    parser = argparse.ArgumentParser(
        description="Write a sample Iceberg suppliers table to S3 and register it in Glue."
    )
    parser.add_argument("--region", default="ap-southeast-2")
    args = parser.parse_args()

    print("Resolving raw bucket from SSM...")
    bucket = get_raw_bucket(args.region)
    s3_location = f"s3://{bucket}/iceberg/suppliers"
    print(f"  Bucket   : {bucket}")
    print(f"  Location : {s3_location}\n")

    # ── Glue catalog ───────────────────────────────────────────────────────────
    # PyIceberg talks to Glue directly — no crawler, no DDL needed.
    # The Glue database (namespace) and table are created in the same step.
    print("Connecting to Glue catalog...")
    catalog = load_catalog(
        "glue",
        **{
            "type":      "glue",
            "region_name": args.region,
            # PyIceberg uses s3fs for file I/O — credentials come from the
            # standard AWS credential chain (CLI profile, env vars, IAM role).
            "s3.region": args.region,
        },
    )

    # ── Namespace (Glue database) ───────────────────────────────────────────────
    existing_namespaces = [ns[0] for ns in catalog.list_namespaces()]
    if NAMESPACE not in existing_namespaces:
        catalog.create_namespace(
            NAMESPACE,
            properties={"comment": "Whitegoods inventory data product — Iceberg tables"},
        )
        print(f"  Created Glue database: {NAMESPACE}")
    else:
        print(f"  Glue database already exists: {NAMESPACE}")

    # ── Drop existing table if present (idempotent re-runs) ────────────────────
    full_name = f"{NAMESPACE}.{TABLE_NAME}"
    try:
        catalog.drop_table(full_name)
        print(f"  Dropped existing table: {full_name}")
    except Exception:
        pass  # table didn't exist — fine

    # ── Schema ─────────────────────────────────────────────────────────────────
    schema = Schema(
        NestedField(1, "supplier_id",    StringType(),  required=True),
        NestedField(2, "name",           StringType(),  required=True),
        NestedField(3, "lead_time_days", IntegerType(), required=True),
        NestedField(4, "contact_email",  StringType(),  required=False),
        NestedField(5, "payment_terms",  StringType(),  required=False),
    )

    # ── Create table (registers in Glue + writes metadata to S3) ───────────────
    print(f"\nCreating Iceberg table in Glue: {full_name}")
    table = catalog.create_table(
        full_name,
        schema=schema,
        location=s3_location,
        properties={
            "write.format.default": "parquet",
            "write.parquet.compression-codec": "snappy",
            "comment": "Sample suppliers Iceberg table — whitegoods_inventory data product",
        },
    )

    # ── Write data (creates Parquet data file + manifest + snapshot) ───────────
    print("Writing supplier rows...")
    arrow_table = pa.table(
        {
            "supplier_id":    pa.array(SUPPLIERS_DATA["supplier_id"],    type=pa.string()),
            "name":           pa.array(SUPPLIERS_DATA["name"],           type=pa.string()),
            "lead_time_days": pa.array(SUPPLIERS_DATA["lead_time_days"], type=pa.int32()),
            "contact_email":  pa.array(SUPPLIERS_DATA["contact_email"],  type=pa.string()),
            "payment_terms":  pa.array(SUPPLIERS_DATA["payment_terms"],  type=pa.string()),
        }
    )
    table.append(arrow_table)
    print(f"  Rows written: {len(arrow_table)}")

    # ── Summary ─────────────────────────────────────────────────────────────────
    print(f"""
Done.

Glue catalog registration:
  Database : {NAMESPACE}
  Table    : {TABLE_NAME}

S3 layout:
  {s3_location}/
  ├── metadata/
  │   ├── v1.metadata.json    ← table schema, partition spec, snapshot history
  │   ├── snap-<id>.avro      ← manifest list (index of manifests)
  │   └── <uuid>.avro         ← manifest (data file locations + column stats)
  └── data/
      └── <uuid>.parquet      ← supplier rows in columnar Snappy-compressed format

Query immediately in Athena (engine v3):
  SELECT * FROM {NAMESPACE}.{TABLE_NAME};

  -- Time travel (every append creates a new snapshot):
  SELECT * FROM {NAMESPACE}.{TABLE_NAME} FOR SYSTEM_TIME AS OF TIMESTAMP '2026-01-01 00:00:00';

Verify files on S3:
  aws s3 ls s3://{bucket}/iceberg/suppliers/ --recursive --region {args.region}

Inspect the Iceberg metadata JSON:
  aws s3 cp $(aws s3 ls s3://{bucket}/iceberg/suppliers/metadata/ \\
    --region {args.region} | grep '.metadata.json' | \\
    awk '{{print "s3://{bucket}/iceberg/suppliers/metadata/"$NF}}') - | python -m json.tool
""")


if __name__ == "__main__":
    main()
