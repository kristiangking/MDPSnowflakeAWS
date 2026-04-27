variable "aws_region" {
  default = "ap-southeast-2"
}

variable "project" {
  default = "mdp-snowflake"
}

variable "environment" {
  default = "dev"
}

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
  default = "TRANSFORMER"
}

variable "snowflake_warehouse" {
  default = "TRANSFORM_WH"
}

variable "snowflake_database" {
  default = "TRANSFORM"
}

variable "snowflake_schema" {
  default = "staging"
}

variable "airflow_instance_type" {
  default = "t3.small"
}