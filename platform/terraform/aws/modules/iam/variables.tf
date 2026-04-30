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

