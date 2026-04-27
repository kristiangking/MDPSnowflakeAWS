output "mwaa_execution_role_arn" {
  value = aws_iam_role.mwaa_execution.arn
}

output "snowflake_secret_arn" {
  value = aws_secretsmanager_secret.snowflake.arn
}