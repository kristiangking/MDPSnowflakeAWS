variable "snowflake_account" {
  description = "Snowflake account identifier"
  default     = "ZKWOWXY-BB01746"
}

variable "snowflake_user" {
  description = "Snowflake admin user for Terraform (requires ACCOUNTADMIN)"
  default     = "tf_service_user"
}

variable "snowflake_password" {
  description = "Password for tf_service_user"
  sensitive   = true
}

variable "dbt_service_password" {
  description = "Password for dbt_service_user"
  sensitive   = true
}
