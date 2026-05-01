variable "project" {}
variable "environment" {}

variable "aws_region" {
  description = "AWS region — passed to Lambda as AWS_REGION env var"
  default     = "ap-southeast-2"
}
