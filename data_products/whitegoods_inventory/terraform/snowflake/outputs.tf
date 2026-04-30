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
  description = "Snowflake-managed SQS ARN shared by all Snowpipes — also written to SSM at /mdp/data_products/whitegoods_inventory/snowpipe_sqs_arn"
  value       = snowflake_pipe.products.notification_channel
}

output "snowflake_iam_user_arn" {
  description = "IAM user ARN Snowflake uses to assume the S3 role — also written to SSM at /mdp/data_products/whitegoods_inventory/snowflake_iam_user_arn"
  value       = snowflake_storage_integration.s3_raw.storage_aws_iam_user_arn
}

output "snowflake_external_id" {
  description = "External ID for the Snowflake IAM role trust policy — also written to SSM at /mdp/data_products/whitegoods_inventory/snowflake_external_id"
  value       = snowflake_storage_integration.s3_raw.storage_aws_external_id
}
