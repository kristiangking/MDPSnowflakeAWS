output "mwaa_execution_role_arn" {
  value = aws_iam_role.mwaa_execution.arn
}

output "snowflake_secret_arn" {
  value = aws_secretsmanager_secret.snowflake.arn
}

output "snowflake_s3_role_arn" {
  description = "ARN of the IAM role Snowflake assumes to access the raw S3 bucket — set as snowflake_iam_role_arn in Snowflake terraform.tfvars for Phase 2"
  value       = aws_iam_role.snowflake_s3.arn
}