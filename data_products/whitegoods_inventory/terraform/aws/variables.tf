variable "aws_region" {
  default = "ap-southeast-2"
}

variable "project" {
  default = "mdp-snowflake"
}

variable "environment" {
  default = "dev"
}

# ── Snowflake trust policy values ──────────────────────────────
# Populated after data product Snowflake apply writes these to SSM.
# Read from SSM with: aws ssm get-parameter --name /mdp/data_products/whitegoods_inventory/snowflake_iam_user_arn
variable "snowflake_iam_user_arn" {
  description = "Snowflake IAM user ARN from storage integration. Use placeholder on Phase 1 apply; update from SSM after Snowflake apply."
  default     = "placeholder"
}

variable "snowflake_external_id" {
  description = "Snowflake external ID for IAM trust policy. Use placeholder on Phase 1 apply; update from SSM after Snowflake apply."
  default     = "placeholder"
}

# ── Snowpipe SQS ARN ───────────────────────────────────────────
# Populated after data product Snowflake apply writes this to SSM.
# Read from SSM with: aws ssm get-parameter --name /mdp/data_products/whitegoods_inventory/snowpipe_sqs_arn
variable "snowpipe_sqs_arn" {
  description = "Snowflake-managed SQS ARN for Snowpipe auto-ingest. Leave empty on Phase 1 apply; update from SSM after Snowflake pipes are created."
  default     = ""
}
