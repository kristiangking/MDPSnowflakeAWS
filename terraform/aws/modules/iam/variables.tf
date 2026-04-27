variable "project" {}
variable "environment" {}
variable "mwaa_bucket_arn" {}
variable "snowflake_account" {}
variable "snowflake_user" {}
variable "snowflake_password" {
  sensitive = true
}
variable "snowflake_role" {}
variable "snowflake_warehouse" {}
variable "snowflake_database" {}
variable "snowflake_schema" {}

variable "raw_bucket_arn" {
  description = "ARN of the raw landing S3 bucket — granted to the Snowflake storage integration role"
}

variable "snowflake_iam_user_arn" {
  description = "Snowflake IAM user ARN from DESC INTEGRATION output. Use placeholder on Phase 1 apply."
  default     = "arn:aws:iam::000000000000:user/placeholder"
}

variable "snowflake_external_id" {
  description = "Snowflake external ID from DESC INTEGRATION output. Use placeholder on Phase 1 apply."
  default     = "placeholder"
}