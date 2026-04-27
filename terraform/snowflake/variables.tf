variable "snowflake_account" {
  description = "Snowflake account identifier"
  default     = "ZKWOWXY-BB01746"
}

variable "snowflake_user" {
  description = "Snowflake admin user for Terraform"
  default     = "tf_service_user"
}

variable "snowflake_password" {
  description = "Snowflake admin password"
  sensitive   = true
}

variable "dbt_service_password" {
  description = "Password for dbt_service_user"
  sensitive   = true
}

variable "snowflake_iam_role_arn" {
  description = "ARN of the AWS IAM role Snowflake assumes for S3 access (output from AWS Phase 1 apply). Use placeholder on first apply."
  default     = "arn:aws:iam::000000000000:role/placeholder"
}
