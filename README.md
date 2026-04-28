# Modern Data Platform — Snowflake on AWS

A production-grade data platform for whitegoods inventory management. Ingests data from S3 and SQS sources via Snowpipe, transforms with dbt Core orchestrated by Airflow on EC2, and serves analytics from Snowflake.

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
  Snowflake RAW.INVENTORY (tables)
        │
      dbt Core
  (Airflow on EC2)
        │
        ▼
  TRANSFORM DB → ANALYTICS DB → Dashboards
```

**Terraform is split into two independent root modules:**
- `terraform/aws/` — VPC, EC2 (Airflow), S3 buckets, SQS queues, Lambda, IAM roles
- `terraform/snowflake/` — Databases, warehouses, roles, storage integration, tables, Snowpipes

There is a deliberate circular dependency between them (explained below). A three-phase apply sequence resolves it.

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

- An AWS account with IAM permissions to create: VPC, EC2, S3, IAM roles/policies, Secrets Manager
- AWS CLI configured with credentials: `aws configure`
- Verify access: `aws sts get-caller-identity`

### Snowflake requirements

- A Snowflake account (trial or paid)
- A user named `TF_SERVICE_USER` with **`ACCOUNTADMIN`** role granted (required to create roles and storage integrations — `SYSADMIN` alone is insufficient)
- Credentials for `TF_SERVICE_USER` stored in `terraform/snowflake/terraform.tfvars`

---

## Repository structure

```
.
├── airflow/
│   └── dags/               # Airflow DAG definitions
├── dbt/
│   └── whitegoods_inventory/  # dbt project (models, tests, sources)
├── lambda/
│   └── sqs_inventory_consumer/
│       └── lambda_function.py  # Lambda source code
├── sample_data/
│   ├── s3_batch/           # CSV files for S3 → Snowpipe ingestion
│   │   ├── reference/      # products.csv, locations.csv, suppliers.csv
│   │   └── transactions/   # purchase_orders.csv, purchase_order_lines.csv
│   └── sqs_events/         # JSON event files for SQS ingestion
├── streamlit/
│   └── whitegoods_inventory/
│       ├── streamlit_app.py    # Streamlit dashboard app
│       └── environment.yml     # Conda environment for Streamlit in Snowflake
└── terraform/
    ├── aws/                # AWS root module
    │   ├── main.tf
    │   ├── variables.tf
    │   ├── outputs.tf
    │   └── modules/
    │       ├── airflow_ec2/    # EC2 instance running Airflow in Docker
    │       ├── iam/            # IAM roles (Snowflake S3 access, MWAA execution)
    │       ├── networking/     # VPC, subnets, security groups
    │       ├── s3/             # MWAA/Airflow S3 bucket
    │       ├── s3_raw/         # Raw landing bucket + Snowpipe event notifications
    │       └── sqs_lambda/     # Inventory events SQS queue, DLQ, Lambda consumer
    └── snowflake/          # Snowflake root module
        ├── main.tf
        ├── variables.tf
        └── outputs.tf
```

---

## Credentials setup

**Never commit credentials to Git.** Both `terraform.tfvars` files are gitignored.

### `terraform/aws/terraform.tfvars`

```hcl
snowflake_password = "your-dbt-service-user-password"

# Populated after Phase 2 (Snowflake apply):
# snowflake_iam_user_arn = "arn:aws:iam::763165855690:user/..."
# snowflake_external_id  = "..."
# snowpipe_sqs_arn       = "arn:aws:sqs:ap-southeast-2:763165855690:sf-snowpipe-..."
```

### `terraform/snowflake/terraform.tfvars`

```hcl
snowflake_password    = "your-tf-service-user-password"
dbt_service_password  = "your-dbt-service-user-password"

# Populated after Phase 1 (AWS apply):
# snowflake_iam_role_arn = "arn:aws:iam::<account_id>:role/mdp-snowflake-dev-snowflake-s3-role"
```

---

## The circular dependency

Two resources depend on each other across cloud boundaries:

**Storage integration ↔ IAM role trust policy**
- The Snowflake storage integration needs the AWS IAM role ARN to know which role to assume
- The AWS IAM role trust policy needs the Snowflake IAM user ARN and external ID (only known after the integration is created)

**Snowpipe SQS ARN ↔ S3 event notifications**
- S3 event notifications need the Snowflake-managed SQS ARN to route events
- That SQS ARN only exists after the Snowpipes are created

**Resolution:** three-phase apply. Phase 1 creates AWS resources with a placeholder trust policy. Phase 2 creates Snowflake resources and outputs the real values. Phase 3 updates AWS with the real values.

---

## Apply sequence

### Phase 1 — AWS first pass

Creates the VPC, EC2 instance (Airflow), S3 buckets, SQS queues, Lambda, and the Snowflake IAM role with a placeholder trust policy.

```bash
cd terraform/aws
terraform init
terraform apply -var-file="terraform.tfvars"
```

**Capture this output** — needed for Phase 2:

```bash
terraform output snowflake_s3_role_arn
```

Update `terraform/snowflake/terraform.tfvars`:
```hcl
snowflake_iam_role_arn = "<value from above>"
```

---

### Phase 2 — Snowflake apply

Creates databases, warehouses, roles, storage integration, schema, tables, and Snowpipes.

```bash
cd terraform/snowflake
terraform init
terraform apply -var-file="terraform.tfvars"
```

> **If the apply fails partway through** (e.g. some resources already exist from a previous attempt), delete the state file and re-apply: `rm -f terraform.tfstate terraform.tfstate.backup && terraform apply -var-file="terraform.tfvars"`. If specific resources already exist in Snowflake but not in state, import them (see import commands below) rather than deleting and recreating.

**Capture these outputs** — needed for Phase 3:

```bash
terraform output snowflake_iam_user_arn
terraform output snowflake_external_id
terraform output snowpipe_sqs_arn
```

Alternatively, run `DESC INTEGRATION S3_RAW_INTEGRATION;` in a Snowflake worksheet to retrieve `STORAGE_AWS_IAM_USER_ARN` and `STORAGE_AWS_EXTERNAL_ID`.

Update `terraform/aws/terraform.tfvars`:
```hcl
snowflake_iam_user_arn = "<snowflake_iam_user_arn output>"
snowflake_external_id  = "<snowflake_external_id output>"
snowpipe_sqs_arn       = "<snowpipe_sqs_arn output>"
```

> **Note on ANALYTICS.MARTS grants:** The grants for the REPORTER role on `ANALYTICS.MARTS` are commented out in `main.tf`. Uncomment and re-apply them **after** running the dbt DAG at least once — the MARTS schema is created by dbt, not Terraform, and the grants will fail if it doesn't exist yet.

---

### Phase 3 — AWS second pass

Updates the Snowflake IAM role trust policy with the real Snowflake principal, and creates the six S3 event notifications that trigger Snowpipe on file arrival.

```bash
cd terraform/aws
terraform apply -var-file="terraform.tfvars"
```

After this apply, the full ingestion pipeline is live:
- Events sent to SQS → Lambda batches → S3 `events/inventory/` → Snowpipe → `RAW.INVENTORY.INVENTORY_EVENTS`
- CSV files uploaded to S3 `reference/` or `transactions/` → Snowpipe → respective RAW tables

---

## Uploading sample data

```bash
cd /path/to/MDPSnowflakeAWS

# Reference and transaction data (triggers Snowpipe via S3 event notifications)
aws s3 cp sample_data/s3_batch/reference/products.csv \
  s3://mdp-raw-landing-kk-<account_id>-ap-southeast-2/reference/products/
aws s3 cp sample_data/s3_batch/reference/locations.csv \
  s3://mdp-raw-landing-kk-<account_id>-ap-southeast-2/reference/locations/
aws s3 cp sample_data/s3_batch/reference/suppliers.csv \
  s3://mdp-raw-landing-kk-<account_id>-ap-southeast-2/reference/suppliers/
aws s3 cp sample_data/s3_batch/transactions/purchase_orders.csv \
  s3://mdp-raw-landing-kk-<account_id>-ap-southeast-2/transactions/purchase_orders/
aws s3 cp sample_data/s3_batch/transactions/purchase_order_lines.csv \
  s3://mdp-raw-landing-kk-<account_id>-ap-southeast-2/transactions/purchase_order_lines/

# Inventory events (sent via SQS → Lambda → S3 → Snowpipe)
python3 - << 'EOF'
import json, boto3, time
sqs = boto3.client('sqs', region_name='ap-southeast-2')
queue_url = '<inventory_events_queue_url output>'
for month in ['jan', 'feb', 'mar']:
    with open(f'sample_data/sqs_events/inventory_events_{month}.json') as f:
        events = json.load(f)
    for event in events:
        sqs.send_message(QueueUrl=queue_url, MessageBody=json.dumps(event))
    print(f'{month}: sent {len(events)} events')
EOF
```

After uploading, verify in Snowflake:
```sql
SELECT COUNT(*) FROM RAW.INVENTORY.PRODUCTS;           -- 12
SELECT COUNT(*) FROM RAW.INVENTORY.LOCATIONS;          -- 7
SELECT COUNT(*) FROM RAW.INVENTORY.SUPPLIERS;          -- 3
SELECT COUNT(*) FROM RAW.INVENTORY.PURCHASE_ORDERS;    -- 39
SELECT COUNT(*) FROM RAW.INVENTORY.PURCHASE_ORDER_LINES; -- 113
SELECT COUNT(*) FROM RAW.INVENTORY.INVENTORY_EVENTS;   -- 636
```

If Snowpipe hasn't picked up files automatically, trigger a manual refresh:
```sql
ALTER PIPE RAW.INVENTORY.PIPE_PRODUCTS REFRESH;
-- repeat for other pipes
```

---

## Running dbt

Trigger the `whitegoods_dbt_pipeline` DAG in Airflow (`http://<airflow_public_ip>:8080`).

To run manually on the EC2 instance:

```bash
ssh ec2-user@<airflow_public_ip>
docker exec airflow-scheduler-1 \
  /home/airflow/.local/bin/dbt run \
  --project-dir /opt/airflow/dbt/whitegoods_inventory \
  --profiles-dir /home/airflow/.dbt
```

After dbt runs, verify mart data:
```sql
SELECT COUNT(*) FROM ANALYTICS.MARTS.MART_INVENTORY_SUMMARY;
```

Then uncomment the ANALYTICS.MARTS grants in `terraform/snowflake/main.tf` and re-apply.

---

## Uploading Streamlit files

The Terraform resource creates the Streamlit app metadata, but the source files must be uploaded separately to the internal stage (this is a Snowflake limitation — stage file uploads are client-side operations outside Terraform's scope).

```bash
# Configure a Snowflake CLI connection (one-time setup)
snow connection add \
  --connection-name mdp \
  --account ZKWOWXY-BB01746 \
  --user tf_service_user \
  --role SYSADMIN \
  --database STREAMLIT_APPS \
  --schema INVENTORY
# Enter password when prompted; press Enter to skip optional fields

# Upload files from repo root
snow stage copy streamlit/whitegoods_inventory/streamlit_app.py \
  @STREAMLIT_APPS.INVENTORY.STREAMLIT_STAGE \
  --connection mdp \
  --overwrite

snow stage copy streamlit/whitegoods_inventory/environment.yml \
  @STREAMLIT_APPS.INVENTORY.STREAMLIT_STAGE \
  --connection mdp \
  --overwrite
```

The dashboard is accessible at:
`https://app.snowflake.com/<org>/<account>/streamlit-apps/STREAMLIT_APPS.INVENTORY.WHITEGOODS_INVENTORY_DASHBOARD`

---

## Airflow access

```
http://<airflow_public_ip>:8080
Username: admin
Password: admin
```

EC2 public IPs change on instance stop/start — check the AWS console or run `terraform output airflow_public_ip` if the IP has changed.

---

## Import commands (fresh-build reference)

These are only needed if Terraform state is out of sync with existing Snowflake/AWS resources.

### AWS

```bash
cd terraform/aws

# Lambda event source mapping
terraform import module.sqs_lambda.aws_lambda_event_source_mapping.sqs \
  <UUID from: aws lambda list-event-source-mappings --function-name sqs-inventory-events-consumer>

# S3 event notification (Phase 3 only)
terraform import 'module.s3_raw.aws_s3_bucket_notification.snowpipe[0]' \
  mdp-raw-landing-kk-<account_id>-ap-southeast-2
```

### Snowflake

> **Important:** Snowflake provider v0.98 uses **dot-separated** identifiers for import IDs, not pipe-separated.

```bash
cd terraform/snowflake

# Databases
terraform import snowflake_database.raw RAW
terraform import snowflake_database.transform TRANSFORM
terraform import snowflake_database.analytics ANALYTICS
terraform import snowflake_database.streamlit_apps STREAMLIT_APPS

# Warehouses
terraform import snowflake_warehouse.loading LOADING_WH
terraform import snowflake_warehouse.transform TRANSFORM_WH
terraform import snowflake_warehouse.report REPORT_WH

# Storage integration
terraform import snowflake_storage_integration.s3_raw S3_RAW_INTEGRATION

# Schemas (dot-separated)
terraform import snowflake_schema.inventory 'RAW.INVENTORY'
terraform import snowflake_schema.streamlit_inventory 'STREAMLIT_APPS.INVENTORY'

# File formats (dot-separated)
terraform import snowflake_file_format.json_array 'RAW.INVENTORY.JSON_ARRAY_FORMAT'
terraform import snowflake_file_format.csv_header 'RAW.INVENTORY.CSV_HEADER_FORMAT'

# Stage (dot-separated)
terraform import snowflake_stage.s3_raw 'RAW.INVENTORY.S3_RAW_STAGE'

# Tables (dot-separated)
terraform import snowflake_table.products            'RAW.INVENTORY.PRODUCTS'
terraform import snowflake_table.locations           'RAW.INVENTORY.LOCATIONS'
terraform import snowflake_table.suppliers           'RAW.INVENTORY.SUPPLIERS'
terraform import snowflake_table.purchase_orders     'RAW.INVENTORY.PURCHASE_ORDERS'
terraform import snowflake_table.purchase_order_lines 'RAW.INVENTORY.PURCHASE_ORDER_LINES'
terraform import snowflake_table.inventory_events    'RAW.INVENTORY.INVENTORY_EVENTS'

# Pipes (dot-separated)
terraform import snowflake_pipe.products             'RAW.INVENTORY.PIPE_PRODUCTS'
terraform import snowflake_pipe.locations            'RAW.INVENTORY.PIPE_LOCATIONS'
terraform import snowflake_pipe.suppliers            'RAW.INVENTORY.PIPE_SUPPLIERS'
terraform import snowflake_pipe.purchase_orders      'RAW.INVENTORY.PIPE_PURCHASE_ORDERS'
terraform import snowflake_pipe.purchase_order_lines 'RAW.INVENTORY.PIPE_PURCHASE_ORDER_LINES'
terraform import snowflake_pipe.inventory_events     'RAW.INVENTORY.PIPE_INVENTORY_EVENTS'
```

---

## Notes

- `terraform.tfvars` files are gitignored — never commit credentials
- The Snowflake provider requires **ACCOUNTADMIN** to create roles and storage integrations
- The raw landing S3 bucket has `force_destroy = false` to prevent accidental data loss
- RAW database tables have `lifecycle { prevent_destroy = true }` as an additional safety net
- All six Snowpipes share a single Snowflake-managed SQS queue — this is expected Snowpipe behaviour
- Warehouse query acceleration is disabled via `lifecycle { ignore_changes = [enable_query_acceleration, query_acceleration_max_scale_factor] }` — required for trial accounts
- The `profiles.yml` on EC2 is owned by UID 50000 (Airflow container user) with permissions 644 — do not change to 600 or the container will not be able to read it
- Lambda timeout is 30s to accommodate S3 PutObject under load
- To send a test SQS event: `aws sqs send-message --queue-url <inventory_events_queue_url> --message-body '{"event_id":"test-1","event_type":"ADJUSTMENT","product_id":"P001","location_id":"L001","qty_delta":-1,"qty_after":99,"reference_id":null,"occurred_at":"2026-04-28T00:00:00Z"}'`
