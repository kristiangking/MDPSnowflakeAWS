output "mwaa_bucket_name" {
  value = aws_s3_bucket.mwaa.id
}

output "mwaa_bucket_arn" {
  value = aws_s3_bucket.mwaa.arn
}