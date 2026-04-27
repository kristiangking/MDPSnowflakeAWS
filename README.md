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
| Git | any | https://git-scm.com |
| SSH client | any | Built-in on macOS/Linux |

### AWS requirements

- An AWS account with IAM permissions to create: VPC, EC2, S3, IAM roles/policies, Secrets Manager
- AWS CLI configured with credentials: `aws configure`
- Verify access: `aws sts get-caller-identity`

### Snowflake requirements

- A Snowflake account (trial or paid)
- A user named `TF_SERVICE_USER` with `SYSADMIN` role granted
- Credentials for `TF_SERVICE_USER` stored in `terraform/snowflake/terraform.tfvars`

---

## Repository structure

```
.
├── airflow/
│   └── dags/               # Airflow DAG definitions
├── dbt/
│   └── whitegoods_inventory/  # dbt project (models, tests, sources)
├── sample_data/            # Seed CSVs and JSON for local testing
└── terraform/
    ├── aws/                # AWS root module
    │   ├── main.tf
    │   ├── variables.tf
    │   ├── outputs.tf
    │   └── modules/
    │       ├── airflow_ec2/    # EC2 instance running Airflow in Docker
    │       ├── iam/            # IAM roles (MWAA execution, Snowflake S3 access)
    │       ├── networking/     # VPC, subnets, security groups
    │       ├── s3/             # MWAA/Airflow S3 bucket
    │       ├── s3_raw/         # Raw landing bucket + Snowpipe event notifications
    │       └── sqs_lambda/     # Inventory events SQS queue, DLQ, Lambda consumer
├── lambda/
│   └── sqs_inventory_consumer/
│       └── lambda_function.py  # Lambda source code
├── streamlit/
│   └── whitegoods_inventory/
│       ├── streamlit_app.py    # Streamlit dashboard app
│       └── environment.yml     # Conda environment for Streamlit in Snowflake
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
# snowflake_iam_role_arn = "arn:aws:iam::277385995606:role/mdp-snowflake-dev-snowflake-s3-role"
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

**Resolution:** three-phase apply. Phase 1 creates AWS resources with placeholder trust policy values. Phase 2 creates Snowflake resources (outputs the real values). Phase 3 updates AWS with the real values.

---

## Apply sequence

### Phase 1 — AWS first pass

Creates the VPC, EC2 instance (Airflow), S3 buckets, and the Snowflake IAM role with a placeholder trust policy.

```bash
cd terraform/aws
terraform init
terraform apply -var-file="terraform.tfvars"
```

**Capture these outputs** — you will need them for Phase 2:

```bash
terraform output snowflake_s3_role_arn
```

Update `terraform/snowflake/terraform.tfvars`:
```hcl
snowflake_iam_role_arn = "<value from above>"
```

**Import existing resources** (first time only — skip if building fresh):

```bash
cd terraform/aws

# Raw landing bucket
terraform import module.s3_raw.aws_s3_bucket.raw \
  mdp-raw-landing-kk-277385995606-ap-southeast-2-an

# Versioning, encryption, public access block
terraform import module.s3_raw.aws_s3_bucket_versioning.raw \
  mdp-raw-landing-kk-277385995606-ap-southeast-2-an
terraform import module.s3_raw.aws_s3_bucket_server_side_encryption_configuration.raw \
  mdp-raw-landing-kk-277385995606-ap-southeast-2-an
terraform import module.s3_raw.aws_s3_bucket_public_access_block.raw \
  mdp-raw-landing-kk-277385995606-ap-southeast-2-an

# Snowflake IAM role (find the existing name in the AWS console)
terraform import module.iam.aws_iam_role.snowflake_s3 \
  <existing-snowflake-iam-role-name>

# SQS queues
terraform import module.sqs_lambda.aws_sqs_queue.dlq \
  https://sqs.ap-southeast-2.amazonaws.com/277385995606/inventory-events-dlq
terraform import module.sqs_lambda.aws_sqs_queue.main \
  https://sqs.ap-southeast-2.amazonaws.com/277385995606/inventory-events-queue

# Lambda function
terraform import module.sqs_lambda.aws_lambda_function.consumer \
  sqs-inventory-events-consumer

# Lambda event source mapping (UUID from: aws lambda list-event-source-mappings --function-name sqs-inventory-events-consumer)
terraform import module.sqs_lambda.aws_lambda_event_source_mapping.sqs \
  9ea0c746-fd25-45a0-bfd6-2aeac0568fa6

# Lambda IAM role — the existing auto-generated role; Terraform will rename it on next apply
terraform import module.sqs_lambda.aws_iam_role.lambda_exec \
  sqs-inventory-events-consumer-role-p11ie553
```

> **Note on the Lambda IAM role:** The existing role has an auto-generated name (`sqs-inventory-events-consumer-role-p11ie553`). Terraform will want to replace it with `mdp-snowflake-dev-sqs-inventory-consumer-role`. This is safe — the Lambda function will be updated to reference the new role, and the old role can be deleted from the AWS console once the apply succeeds.

---

### Phase 2 — Snowflake apply

Creates databases, warehouses, roles, the storage integration (pointing at the Phase 1 IAM role), schema, tables, and Snowpipes.

```bash
cd terraform/snowflake
terraform init
terraform apply -var-file="terraform.tfvars"
```

**Capture these outputs** — you will need them for Phase 3:

```bash
terraform output snowflake_s3_role_arn      # confirm it matches Phase 1
terraform output snowflake_iam_user_arn
terraform output snowflake_external_id
terraform output snowpipe_sqs_arn
```

Update `terraform/aws/terraform.tfvars` with the three values:
```hcl
snowflake_iam_user_arn = "<snowflake_iam_user_arn output>"
snowflake_external_id  = "<snowflake_external_id output>"
snowpipe_sqs_arn       = "<snowpipe_sqs_arn output>"
```

**Import existing Snowflake resources** (first time only — skip if building fresh):

```bash
cd terraform/snowflake

# Storage integration
terraform import snowflake_storage_integration.s3_raw S3_RAW_INTEGRATION

# Schema
terraform import snowflake_schema.inventory RAW|INVENTORY

# File format
terraform import snowflake_file_format.json_array RAW|INVENTORY|JSON_ARRAY_FORMAT

# Stage
terraform import snowflake_stage.s3_raw RAW|INVENTORY|S3_RAW_STAGE

# Tables
terraform import snowflake_table.products            RAW|INVENTORY|PRODUCTS
terraform import snowflake_table.locations           RAW|INVENTORY|LOCATIONS
terraform import snowflake_table.suppliers           RAW|INVENTORY|SUPPLIERS
terraform import snowflake_table.purchase_orders     RAW|INVENTORY|PURCHASE_ORDERS
terraform import snowflake_table.purchase_order_lines RAW|INVENTORY|PURCHASE_ORDER_LINES
terraform import snowflake_table.inventory_events    RAW|INVENTORY|INVENTORY_EVENTS

# Pipes
terraform import snowflake_pipe.products             RAW|INVENTORY|PIPE_PRODUCTS
terraform import snowflake_pipe.locations            RAW|INVENTORY|PIPE_LOCATIONS
terraform import snowflake_pipe.suppliers            RAW|INVENTORY|PIPE_SUPPLIERS
terraform import snowflake_pipe.purchase_orders      RAW|INVENTORY|PIPE_PURCHASE_ORDERS
terraform import snowflake_pipe.purchase_order_lines RAW|INVENTORY|PIPE_PURCHASE_ORDER_LINES
terraform import snowflake_pipe.inventory_events     RAW|INVENTORY|PIPE_INVENTORY_EVENTS
```

# Streamlit resources (STREAMLIT_APPS database was created manually)
terraform import snowflake_database.streamlit_apps STREAMLIT_APPS
terraform import snowflake_schema.streamlit_inventory STREAMLIT_APPS|INVENTORY

# The existing Streamlit has an auto-generated name — a new properly-named one
# will be created by Terraform. Drop the old one manually from the Snowflake UI:
#   STREAMLIT_APPS.INVENTORY.N1EYWG3VS6AOZJY9
# Also drop TRANSFORM_OLD database if no longer needed:
#   DROP DATABASE TRANSFORM_OLD;
```

After applying, upload the Streamlit app files to the named stage (requires SnowSQL):

```bash
# Install SnowSQL if not already present: https://docs.snowflake.com/en/user-guide/snowsql-install-config
snowsql -a ZKWOWXY-BB01746 -u tf_service_user -r SYSADMIN \
  -q "PUT file://streamlit/whitegoods_inventory/streamlit_app.py @STREAMLIT_APPS.INVENTORY.STREAMLIT_STAGE OVERWRITE=TRUE AUTO_COMPRESS=FALSE"

snowsql -a ZKWOWXY-BB01746 -u tf_service_user -r SYSADMIN \
  -q "PUT file://streamlit/whitegoods_inventory/environment.yml @STREAMLIT_APPS.INVENTORY.STREAMLIT_STAGE OVERWRITE=TRUE AUTO_COMPRESS=FALSE"
```

Once uploaded, the dashboard is accessible at:
`https://app.snowflake.com/<org>/<account>/streamlit-apps/STREAMLIT_APPS.INVENTORY.WHITEGOODS_INVENTORY_DASHBOARD`

> **Note on query warehouse:** The existing app used `TRANSFORM_WH`. Terraform sets it to `REPORT_WH` (the designated reporting warehouse). If you prefer to keep `TRANSFORM_WH`, update `query_warehouse = snowflake_warehouse.report.name` to `snowflake_warehouse.transform.name` in `main.tf`.

> **Note on ANALYTICS.MARTS grants:** The `analytics_marts_schema_reporter` and `analytics_marts_tables_reporter` grants will fail if dbt has not yet run (the MARTS schema is created by dbt, not Terraform). Run `dbt run` at least once before applying these grants, or apply them in a separate pass after dbt has executed.

> **Before applying after import:** Run `terraform plan` and review it carefully. Pay special attention to any table column changes — the declared column types in `main.tf` are best-effort estimates based on COPY INTO definitions. If the plan shows unexpected column modifications, run `SELECT GET_DDL('TABLE', 'RAW.INVENTORY.<TABLE_NAME>');` in a Snowflake worksheet to get the exact DDL and reconcile the types before applying. The tables have `lifecycle { prevent_destroy = true }` as a safety net.

---

### Phase 3 — AWS second pass

Updates the Snowflake IAM role trust policy with the real Snowflake principal, and creates the five S3 event notifications that trigger Snowpipe on file arrival.

```bash
cd terraform/aws
terraform apply -var-file="terraform.tfvars"
```

**Import the existing S3 event notification config** (first time only):

```bash
terraform import 'module.s3_raw.aws_s3_bucket_notification.snowpipe[0]' \
  mdp-raw-landing-kk-277385995606-ap-southeast-2-an
```

After this apply, the full ingestion pipeline is live:
- Events sent to SQS → Lambda batches → S3 `events/inventory/` → Snowpipe auto-ingest → `RAW.INVENTORY.INVENTORY_EVENTS`
- CSV files dropped into S3 `reference/` or `transactions/` → Snowpipe auto-ingest → respective RAW tables

---

## Airflow access

Airflow starts automatically on EC2 boot (via Docker Compose). After Phase 1 completes:

```
http://<airflow_public_ip>:8080
Username: admin
Password: admin
```

The `airflow_public_ip` is printed as a Terraform output after the Phase 1 apply. Note that EC2 public IPs change on instance stop/start — check the AWS console or re-run `terraform output` if the IP has changed.

---

## dbt

dbt runs inside the Airflow container via the `whitegoods_dbt_dag` DAG. To run it manually on the EC2 instance:

```bash
ssh ec2-user@<airflow_public_ip>

# Run dbt inside the scheduler container
docker exec airflow-scheduler-1 \
  /home/airflow/.local/bin/dbt run \
  --project-dir /opt/airflow/dbt/whitegoods_inventory \
  --profiles-dir /home/airflow/.dbt
```

---

## Notes

- `terraform.tfvars` files are gitignored — never commit credentials
- The raw landing S3 bucket has `force_destroy = false` to prevent accidental data loss
- RAW database tables have `lifecycle { prevent_destroy = true }` as an additional safety net
- All six Snowpipes share a single Snowflake-managed SQS queue — this is expected Snowpipe behaviour
- Lambda timeout is set to 30s (the original auto-created function used 3s, which is too short for S3 PutObject under load)
- The Lambda `RAW_BUCKET` environment variable is managed by Terraform; the original hardcoded value has been removed
- To send a test event to SQS manually: `aws sqs send-message --queue-url <inventory_events_queue_url output> --message-body '{"event_id":"test-1","event_type":"ADJUSTMENT","product_id":"P001","location_id":"L001","qty_delta":-1,"qty_after":99,"reference_id":null,"occurred_at":"2026-04-27T00:00:00Z"}'`
