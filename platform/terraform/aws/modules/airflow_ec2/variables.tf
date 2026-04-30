variable "project" {}
variable "environment" {}
variable "vpc_id" {}
variable "public_subnet_id" {}
variable "instance_type" {}
variable "airflow_execution_role" {}
variable "snowflake_secret_arn" {}
variable "airflow_s3_bucket" {
  description = "Name of the Airflow S3 bucket. Data products upload DAGs to dags/ prefix here; EC2 syncs from it every minute."
}