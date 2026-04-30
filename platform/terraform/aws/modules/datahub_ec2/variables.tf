variable "project" {}
variable "environment" {}
variable "vpc_id" {}
variable "public_subnet_id" {}
variable "instance_type" {
  default = "t3.large"
}

variable "airflow_s3_bucket" {
  description = "Airflow S3 bucket name — DataHub reads dbt artifacts from datahub/dbt/ prefix here."
}

variable "snowflake_account" {
  description = "Snowflake account identifier used in ingestion recipes."
}

variable "snowflake_password" {
  description = "TF_SERVICE_USER password — used by DataHub Snowflake ingestion (requires ACCOUNTADMIN)."
  sensitive   = true
}

variable "airflow_host" {
  description = "Public IP or hostname of the Airflow EC2 — used for Airflow REST API ingestion."
}
