variable "project" {}
variable "environment" {}

variable "raw_bucket_name" {
  description = "Name of the raw landing S3 bucket — passed to Lambda as RAW_BUCKET env var"
}

variable "raw_bucket_arn" {
  description = "ARN of the raw landing S3 bucket — granted PutObject to the Lambda execution role"
}
