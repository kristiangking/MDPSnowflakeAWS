variable "project" {}
variable "environment" {}
variable "aws_region" {}

variable "snowpipe_sqs_arn" {
  description = "Snowflake-managed SQS ARN for Snowpipe auto-ingest (output from Snowflake apply). Leave empty on Phase 1 apply."
  default     = ""
}
