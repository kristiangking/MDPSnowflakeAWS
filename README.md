# Modern Data Platform — Snowflake on AWS

A production-grade data platform for whitegoods inventory management. Ingests data from S3 and SQS sources via Snowpipe, transforms with dbt Core orchestrated by Airflow on EC2, and serves analytics from Snowflake.

See [ARCHITECTURE.md](./ARCHITECTURE.md) for the design decisions behind this structure.

---

## Repository structure

```
.
├── platform/
│   └── terraform/
│       ├── aws/                    # VPC, EC2 (Airflow), Airflow S3 bucket, IAM, Secrets Manager
│       │   └── modules/
│       │       ├── airflow_ec2/
│       │       ├── iam/
│       │       ├── networking/
│       │       └── s3/
│       └── snowflake/              # dbt_service_user only
│
└── data_products/
    └── whitegoods_inventory/
        ├── terraform/
        │   ├── aws/                # S3 raw bucket, SQS, Lambda, Snowflake S3 IAM role
        │   │   └── modules/
        │   │       ├── s3_raw/
        │   │       └── sqs_lambda/
        │   └── snowflake/          # Databases, warehouses, roles, storage integration,
        │                           # schemas, tables, pipes, grants (all WHITEGOODS_ prefixed)
        ├── dbt/
        │   └── whitegoods_inventory/
        ├── airflow/
        │   └── dags/
        ├── lambda/
        │   └── sqs_inventory_consumer/
        ├── streamlit/
        │   └── whitegoods_inventory/
        └── sample_data/
```

---

## Architecture overview

```
Application / producer
        │
        ▼
  SQS (inventory-events-queue)
        │  maxReceiveCount=3
        ├──► DLQ (inventory-events-dlq)
        │
        ▼
  Lambda (sqs-inventory-events-consumer)
        │  batches events → JSON array
        ▼
  S3 raw landing bucket
  ├── events/inventory/YYYY/MM/DD/<uuid>.json  ◄── Lambda writes here
  ├── reference/products/
  ├── reference/locations/
  ├── reference/suppliers/
  ├── transactions/purchase_orders/
  └── transactions/purchase_order_lines/
        │
        │ S3 event notifications → Snowflake SQS
        ▼
  Snowpipe (auto-ingest)
        │
        ▼
  WHITEGOODS_RAW.INVENTORY (tables)
        │
      dbt Core
  (Airflow on EC2)
        │
        ▼
  WHITEGOODS_TRANSFORM → WHITEGOODS_ANALYTICS → Dashboards (Streamlit)
```

**SSM Parameter Store** is used as the integration layer between the platform and data product Terraform modules. See ARCHITECTURE.md ADR-003 for rationale.

---

## Prerequisites

### Local tools

| Tool | Version | Install |
|---|---|---|
| Terraform | >= 1.5 | https://developer.hashicorp.com/terraform/install |
| AWS CLI | >= 2.x | https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html |
| Snowflake CLI | >= 2.x | `pip install snowflake-cli` |
| Git | any | https://git-scm.com |
| SSH client | any | Built-in on macOS/Linux |

### AWS requirements

- An AWS account with IAM permissions to create: VPC, EC2, S3, IAM roles/policies, Secrets Manager, SSM Parameter Store
- AWS CLI configured: `aws configure`
- Verify access: `aws sts get-caller-identity`

### Snowflake requirements

- A Snowflake account (trial or paid)
- A user named `TF_SERVICE_USER` with **`ACCOUNTADMIN`** role granted
- `dbt_service_user` is created automatically by platform Terraform

---

## Credentials setup

**Never commit credentials to Git.** All `terraform.tfvars` files are gitignored.

### `platform/terraform/aws/terraform.tfvars`

```hcl
snowflake_password = "your-dbt-service-user-password"
```

### `platform/terraform/snowflake/terraform.tfvars`

```hcl
snowflake_password    = "your-tf-service-user-password"
dbt_service_password  = "your-dbt-service-user-password"
```

### `data_products/whitegoods_inventory/terraform/aws/terraform.tfvars`

```hcl
# Phase 1: leave as defaults (placeholder / empty)
# Steps 5 and 7: update with values read from SSM (see apply sequence below)
# snowflake_iam_user_arn = "arn:aws:iam::763165855690:user/..."
# snowflake_external_id  = "..."
# snowpipe_sqs_arn       = "arn:aws:sqs:ap-southeast-2:763165855690:sf-snowpipe-..."
```

### `data_products/whitegoods_inventory/terraform/snowflake/terraform.tfvars`

```hcl
snowflake_password = "your-tf-service-user-password"
```

---

## Apply sequence

There is a circular dependency between the Snowflake storage integration and the AWS IAM role trust policy, both owned by the data product. This requires a multi-step apply sequence.

### Step 1 — Platform AWS

Creates VPC, EC2 (Airflow), Airflow S3 bucket, IAM roles, Secrets Manager. Writes `airflow_public_ip` and `airflow_s3_bucket` to SSM.

```bash
cd platform/terraform/aws
terraform init
terraform apply -var-file="terraform.tfvars"
```

### Step 2 — Platform Snowflake

Creates `dbt_service_user`.

```bash
cd platform/terraform/snowflake
terraform init
terraform apply -var-file="terraform.tfvars"
```

### Step 3 — Data product AWS (Phase 1)

Creates S3 raw bucket, SQS, Lambda, and the Snowflake S3 IAM role with a placeholder trust policy. Writes `snowflake_s3_role_arn` and `raw_bucket_name` to SSM.

```bash
cd data_products/whitegoods_inventory/terraform/aws
terraform init
terraform apply -var-file="terraform.tfvars"
```

### Step 4 — Data product Snowflake (Phase 1)

Creates databases, warehouses, roles, storage integration (reads `snowflake_s3_role_arn` from SSM automatically), schemas, tables. Writes `snowflake_iam_user_arn` and `snowflake_external_id` to SSM. Pipes will fail here — this is expected.

```bash
cd data_products/whitegoods_inventory/terraform/snowflake

# Always clear stale state before applying on a fresh Snowflake account
rm -f terraform.tfstate terraform.tfstate.backup

terraform init
terraform apply -var-file="terraform.tfvars"
```

### Step 5 — Data product AWS (Phase 2): fix trust policy

Read the Snowflake values from SSM:

```bash
aws ssm get-parameter --name /mdp/data_products/whitegoods_inventory/snowflake_iam_user_arn --query Parameter.Value --output text
aws ssm get-parameter --name /mdp/data_products/whitegoods_inventory/snowflake_external_id --query Parameter.Value --output text
```

Add those values to `data_products/whitegoods_inventory/terraform/aws/terraform.tfvars`, then apply targeting just the IAM role:

```bash
cd data_products/whitegoods_inventory/terraform/aws
terraform apply -target='aws_iam_role.snowflake_s3' -var-file="terraform.tfvars"
```

### Step 6 — Data product Snowflake (Phase 2): create pipes

Trust policy is now correct, so all 6 pipes will be created. Also writes `snowpipe_sqs_arn` to SSM.

```bash
cd data_products/whitegoods_inventory/terraform/snowflake
terraform apply -var-file="terraform.tfvars"
```

### Step 7 — Data product AWS (Phase 3): S3 event notifications

Read the Snowpipe SQS ARN from SSM:

```bash
aws ssm get-parameter --name /mdp/data_products/whitegoods_inventory/snowpipe_sqs_arn --query Parameter.Value --output text
```

Add `snowpipe_sqs_arn` to `data_products/whitegoods_inventory/terraform/aws/terraform.tfvars`, then full apply:

```bash
cd data_products/whitegoods_inventory/terraform/aws
terraform apply -var-file="terraform.tfvars"
```

The full ingestion pipeline is now live.

---

## Uploading sample data

```bash
cd data_products/whitegoods_inventory

RAW_BUCKET=$(aws ssm get-parameter --name /mdp/data_products/whitegoods_inventory/raw_bucket_name --query Parameter.Value --output text)

aws s3 cp sample_data/s3_batch/reference/products.csv      s3://$RAW_BUCKET/reference/products/
aws s3 cp sample_data/s3_batch/reference/locations.csv     s3://$RAW_BUCKET/reference/locations/
aws s3 cp sample_data/s3_batch/reference/suppliers.csv     s3://$RAW_BUCKET/reference/suppliers/
aws s3 cp sample_data/s3_batch/transactions/purchase_orders.csv      s3://$RAW_BUCKET/transactions/purchase_orders/
aws s3 cp sample_data/s3_batch/transactions/purchase_order_lines.csv s3://$RAW_BUCKET/transactions/purchase_order_lines/

# Inventory events via SQS → Lambda → S3 → Snowpipe
QUEUE_URL=$(aws ssm get-parameter --name /mdp/data_products/whitegoods_inventory/inventory_events_queue_url --query Parameter.Value --output text 2>/dev/null || \
  terraform -chdir=terraform/aws output -raw inventory_events_queue_url)

python3 - << 'EOF'
import json, boto3, os
sqs = boto3.client('sqs', region_name='ap-southeast-2')
queue_url = '<inventory_events_queue_url from terraform output>'
for month in ['jan', 'feb', 'mar']:
    with open(f'sample_data/sqs_events/inventory_events_{month}.json') as f:
        events = json.load(f)
    for event in events:
        sqs.send_message(QueueUrl=queue_url, MessageBody=json.dumps(event))
    print(f'{month}: sent {len(events)} events')
EOF
```

Verify in Snowflake:

```sql
SELECT COUNT(*) FROM WHITEGOODS_RAW.INVENTORY.PRODUCTS;              -- 12
SELECT COUNT(*) FROM WHITEGOODS_RAW.INVENTORY.LOCATIONS;             -- 7
SELECT COUNT(*) FROM WHITEGOODS_RAW.INVENTORY.SUPPLIERS;             -- 3
SELECT COUNT(*) FROM WHITEGOODS_RAW.INVENTORY.PURCHASE_ORDERS;       -- 39
SELECT COUNT(*) FROM WHITEGOODS_RAW.INVENTORY.PURCHASE_ORDER_LINES;  -- 113
SELECT COUNT(*) FROM WHITEGOODS_RAW.INVENTORY.INVENTORY_EVENTS;      -- 636
```

If Snowpipe hasn't picked up files automatically, trigger a manual refresh:

```sql
ALTER PIPE WHITEGOODS_RAW.INVENTORY.PIPE_PRODUCTS REFRESH;
-- repeat for other pipes
```

---

## Running dbt

Get the Airflow IP:

```bash
aws ssm get-parameter --name /mdp/platform/airflow_public_ip --query Parameter.Value --output text
```

Open `http://<airflow_public_ip>:8080` (admin / admin), find `whitegoods_dbt_pipeline` and trigger it.

After dbt runs, verify:

```sql
SELECT COUNT(*) FROM WHITEGOODS_ANALYTICS.MARTS.MART_INVENTORY_SUMMARY;  -- 36
```

Then uncomment the `ANALYTICS.MARTS` grants in `data_products/whitegoods_inventory/terraform/snowflake/main.tf` and re-apply Step 4.

---

## Uploading Streamlit files

```bash
# One-time connection setup
snow connection add \
  --connection-name mdp \
  --account ZKWOWXY-BB01746 \
  --user tf_service_user \
  --role SYSADMIN \
  --database WHITEGOODS_STREAMLIT_APPS \
  --schema INVENTORY

snow stage copy data_products/whitegoods_inventory/streamlit/whitegoods_inventory/streamlit_app.py \
  @WHITEGOODS_STREAMLIT_APPS.INVENTORY.STREAMLIT_STAGE \
  --connection mdp --overwrite

snow stage copy data_products/whitegoods_inventory/streamlit/whitegoods_inventory/environment.yml \
  @WHITEGOODS_STREAMLIT_APPS.INVENTORY.STREAMLIT_STAGE \
  --connection mdp --overwrite
```

Dashboard: `https://app.snowflake.com/<org>/<account>/streamlit-apps/WHITEGOODS_STREAMLIT_APPS.INVENTORY.WHITEGOODS_INVENTORY_DASHBOARD`

---

## SSM parameter reference

| Parameter | Written by | Purpose |
|---|---|---|
| `/mdp/platform/airflow_public_ip` | Platform AWS | Discoverability |
| `/mdp/platform/airflow_s3_bucket` | Platform AWS | Discoverability |
| `/mdp/data_products/whitegoods_inventory/snowflake_s3_role_arn` | Data product AWS | Read by data product Snowflake for storage integration |
| `/mdp/data_products/whitegoods_inventory/raw_bucket_name` | Data product AWS | Discoverability |
| `/mdp/data_products/whitegoods_inventory/snowflake_iam_user_arn` | Data product Snowflake | Read by data product AWS for trust policy update |
| `/mdp/data_products/whitegoods_inventory/snowflake_external_id` | Data product Snowflake | Read by data product AWS for trust policy update |
| `/mdp/data_products/whitegoods_inventory/snowpipe_sqs_arn` | Data product Snowflake | Read by data product AWS for S3 event notifications |

---

## Notes

- `terraform.tfvars` files are gitignored — never commit credentials
- ACCOUNTADMIN is required to create storage integrations — see ADR-004 in ARCHITECTURE.md for the future hardening plan
- The raw landing S3 bucket has `force_destroy = false` to prevent accidental data loss
- RAW database tables have `lifecycle { prevent_destroy = true }` as a safety net
- All six Snowpipes share a single Snowflake-managed SQS queue — expected Snowpipe behaviour
- Warehouse `query_acceleration` settings are ignored via lifecycle — required for trial accounts
- The `profiles.yml` on EC2 is owned by UID 50000 (Airflow container user) with permissions 644
- Lambda timeout is 30s to accommodate S3 PutObject under load
