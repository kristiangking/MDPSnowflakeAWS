variable "aws_region" {
  default = "ap-southeast-2"
}

variable "project" {
  default = "mdp-snowflake"
}

variable "environment" {
  default = "dev"
}

variable "airflow_instance_type" {
  default = "t3.small"
}

variable "datahub_instance_type" {
  default = "t3.large"
}

variable "datahub_snowflake_password" {
  description = "TF_SERVICE_USER password — used by DataHub Snowflake ingestion (ACCOUNTADMIN required to crawl all databases)."
  sensitive   = true
}

# ── Snowflake dbt service account credentials ──────────────────
# Stored in Secrets Manager so Airflow can retrieve them at runtime.
variable "snowflake_account" {
  description = "Snowflake account identifier"
  default     = "ZKWOWXY-BB01746"
}

variable "snowflake_user" {
  description = "dbt service account username"
  default     = "dbt_service_user"
}

variable "snowflake_password" {
  description = "dbt service account password"
  sensitive   = true
}

variable "snowflake_role" {
  default = "WHITEGOODS_TRANSFORMER"
}

variable "snowflake_warehouse" {
  default = "WHITEGOODS_TRANSFORM_WH"
}

variable "snowflake_database" {
  default = "WHITEGOODS_TRANSFORM"
}

variable "snowflake_schema" {
  default = "staging"
}
