variable "aws_region" {
  description = "AWS region — used by the AWS provider to write SSM parameters"
  default     = "ap-southeast-2"
}

variable "snowflake_account" {
  description = "Snowflake account identifier"
  default     = "ZKWOWXY-BB01746"
}

variable "snowflake_user" {
  description = "Snowflake admin user for Terraform (requires ACCOUNTADMIN — see ADR-004)"
  default     = "tf_service_user"
}

variable "snowflake_password" {
  description = "Password for tf_service_user"
  sensitive   = true
}
