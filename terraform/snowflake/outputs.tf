output "raw_database" {
  value = snowflake_database.raw.name
}

output "transform_database" {
  value = snowflake_database.transform.name
}

output "analytics_database" {
  value = snowflake_database.analytics.name
}

output "loader_role" {
  value = snowflake_account_role.loader.name
}

output "transformer_role" {
  value = snowflake_account_role.transformer.name
}

output "reporter_role" {
  value = snowflake_account_role.reporter.name
}

output "snowpipe_sqs_arn" {
  description = "Snowflake-managed SQS ARN shared by all Snowpipes — set as snowpipe_sqs_arn in AWS terraform.tfvars for Phase 3"
  value       = snowflake_pipe.products.notification_channel
}

output "snowflake_iam_user_arn" {
  description = "IAM user ARN Snowflake uses to assume the S3 role — set as snowflake_iam_user_arn in AWS terraform.tfvars for Phase 3"
  value       = snowflake_storage_integration.s3_raw.storage_aws_iam_user_arn
}

output "snowflake_external_id" {
  description = "External ID for the Snowflake IAM role trust policy — set as snowflake_external_id in AWS terraform.tfvars for Phase 3"
  value       = snowflake_storage_integration.s3_raw.storage_aws_external_id
}
