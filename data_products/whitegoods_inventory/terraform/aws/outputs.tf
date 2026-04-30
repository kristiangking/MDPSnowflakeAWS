output "raw_bucket_name" {
  description = "Raw landing S3 bucket name"
  value       = module.s3_raw.bucket_name
}

output "snowflake_s3_role_arn" {
  description = "IAM role ARN for Snowflake storage integration — also written to SSM at /mdp/data_products/whitegoods_inventory/snowflake_s3_role_arn"
  value       = aws_iam_role.snowflake_s3.arn
}

output "inventory_events_queue_url" {
  description = "SQS queue URL for sending inventory events"
  value       = module.sqs_lambda.queue_url
}

output "inventory_events_queue_arn" {
  description = "SQS queue ARN"
  value       = module.sqs_lambda.queue_arn
}
