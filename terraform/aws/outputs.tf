output "airflow_public_ip" {
  value = module.airflow_ec2.public_ip
}

output "mwaa_bucket_name" {
  value = module.s3.mwaa_bucket_name
}

output "snowflake_secret_arn" {
  value = module.iam.snowflake_secret_arn
}

output "raw_bucket_name" {
  description = "Raw landing S3 bucket name"
  value       = module.s3_raw.bucket_name
}

output "snowflake_s3_role_arn" {
  description = "IAM role ARN for Snowflake storage integration — set as snowflake_iam_role_arn in Snowflake terraform.tfvars for Phase 2"
  value       = module.iam.snowflake_s3_role_arn
}

output "inventory_events_queue_url" {
  description = "SQS queue URL for sending inventory events"
  value       = module.sqs_lambda.queue_url
}

output "inventory_events_queue_arn" {
  description = "SQS queue ARN for sending inventory events"
  value       = module.sqs_lambda.queue_arn
}