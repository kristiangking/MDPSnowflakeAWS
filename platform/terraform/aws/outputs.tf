output "airflow_public_ip" {
  value = module.airflow_ec2.public_ip
}

output "airflow_s3_bucket" {
  value = module.s3.mwaa_bucket_name
}

output "snowflake_secret_arn" {
  value = module.iam.snowflake_secret_arn
}
