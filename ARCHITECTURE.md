# Architecture Decision Record

This document captures the key architectural decisions made for this platform, the reasoning behind them, and any known trade-offs or future hardening items.

---

## ADR-001: Platform vs Data Product separation

### Decision

The repository is structured into two top-level concerns:

- **`platform/`** — infrastructure managed by a platform team. Changes infrequently, requires elevated permissions, has a high blast radius.
- **`data_products/`** — everything owned by data engineers for a specific data product. Changes frequently, lower blast radius, scoped to one product.

### Platform owns
- AWS networking (VPC, subnets, NAT gateway, security groups)
- EC2 instance running Airflow (the execution environment, not the DAGs)
- Airflow S3 bucket (the platform's operational storage)
- AWS IAM roles for EC2 and the Snowflake S3 storage integration
- Snowflake `dbt_service_user` (the credential is shared infrastructure)

### Data product owns
- S3 raw landing bucket
- SQS queue and Lambda consumer
- Snowflake databases, warehouses, roles, storage integration
- Snowflake schemas, file formats, stages, tables, pipes, grants
- Streamlit database and application
- dbt project
- Airflow DAGs
- Lambda function code
- Sample data

### Rationale

A platform team needs stability and control over shared infrastructure. Data engineers need autonomy and fast iteration over their own schemas, pipelines, and models. Mixing these concerns in a single Terraform root forces data engineers to coordinate with the platform team for routine changes, and gives them access to resources they should not be able to modify.

Separating them also enables cost isolation per data product (dedicated warehouses) and data isolation (dedicated roles and databases), which are requirements as the platform grows to support multiple products.

---

## ADR-002: Snowflake object naming convention

### Decision

Snowflake objects belonging to a data product are prefixed with the data product name in uppercase. For the whitegoods inventory product:

| Object type | Name |
|---|---|
| Databases | `WHITEGOODS_RAW`, `WHITEGOODS_TRANSFORM`, `WHITEGOODS_ANALYTICS` |
| Warehouses | `WHITEGOODS_LOADING_WH`, `WHITEGOODS_TRANSFORM_WH`, `WHITEGOODS_REPORT_WH` |
| Roles | `WHITEGOODS_LOADER`, `WHITEGOODS_TRANSFORMER`, `WHITEGOODS_REPORTER` |
| Storage integration | `WHITEGOODS_S3_RAW_INTEGRATION` |

### Rationale

Unprefixed names (`RAW`, `TRANSFORM`, `ANALYTICS`) collide when a second data product is onboarded. Prefixing from the start avoids a painful rename migration later and makes the ownership of each object unambiguous in the Snowflake UI.

---

## ADR-003: SSM Parameter Store as the integration layer between platform and data product

### Decision

Cross-boundary values between the platform Terraform module and the data product Terraform module are exchanged via AWS SSM Parameter Store, not via Terraform remote state references or manually copied variables.

- The platform writes its outputs (e.g. `snowflake_s3_role_arn`, `airflow_public_ip`) to SSM under `/mdp/platform/`.
- The data product reads those values from SSM as data sources.
- The data product writes its outputs (e.g. `snowflake_iam_user_arn`, `snowflake_external_id`, `snowpipe_sqs_arn`) to SSM under `/mdp/data_products/whitegoods_inventory/`.
- The platform reads those values back from SSM to update the IAM trust policy and S3 event notifications.

### Rationale

The platform and data product modules have a deliberate circular dependency (Snowflake storage integration ↔ AWS IAM trust policy). They must be applied in sequence, but they must not share Terraform state — giving a data engineer access to platform state would allow them to read or modify platform resources.

Three alternatives were considered:

| Option | Problem |
|---|---|
| `terraform_remote_state` | Requires the data product to have read access to the platform state backend, which may contain sensitive platform values |
| Manually copying outputs into `terraform.tfvars` | Error-prone, not automatable, breaks the boundary — a human must bridge the two modules |
| SSM Parameter Store | Clean boundary: each module only sees its own state. SSM paths act as a well-defined contract. Values are versioned and auditable. IAM policies can restrict which principals can read which parameters. |

SSM adds a small amount of complexity (parameters must be created before they are read) but the apply sequence already requires ordered phases due to the circular dependency, so this is not an additional constraint in practice.

### SSM parameter paths

```
/mdp/platform/snowflake_s3_role_arn
/mdp/platform/airflow_public_ip
/mdp/platform/airflow_s3_bucket

/mdp/data_products/whitegoods_inventory/snowflake_iam_user_arn
/mdp/data_products/whitegoods_inventory/snowflake_external_id
/mdp/data_products/whitegoods_inventory/snowpipe_sqs_arn
/mdp/data_products/whitegoods_inventory/raw_bucket_name
```

---

## ADR-004: ACCOUNTADMIN for data product Terraform (known limitation)

### Decision

The data product Terraform module currently runs as `ACCOUNTADMIN` because Snowflake requires `ACCOUNTADMIN` to create storage integrations (`CREATE INTEGRATION`).

### Future hardening

Create a dedicated `TF_DATA_USER` Snowflake user with only the privileges it needs:

```sql
GRANT CREATE INTEGRATION ON ACCOUNT TO ROLE SYSADMIN;
-- or a custom role with just CREATE INTEGRATION + SYSADMIN-level DB/warehouse creation
```

This reduces the blast radius of a compromised `TF_DATA_USER` credential. Until then, the `TF_SERVICE_USER` credential used by data product Terraform should be stored in AWS Secrets Manager and rotated regularly.

---

## ADR-005: Mono-repo with folder boundaries

### Decision

All platform and data product code lives in a single repository under clearly defined top-level folders.

### Rationale

A mono-repo is simpler to operate when there is one data product and one team. It avoids cross-repo dependency management, keeps the full system visible in one place, and makes the onboarding path for a new data engineer straightforward.

When a second data product is onboarded, the cost of the mono-repo (merge contention, larger clone) should be reassessed. At that point, extracting each data product into its own repository — with the platform remaining as a shared repo — becomes attractive.
