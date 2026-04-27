terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

module "networking" {
  source      = "./modules/networking"
  project     = var.project
  environment = var.environment
}

module "s3" {
  source      = "./modules/s3"
  project     = var.project
  environment = var.environment
}

module "s3_raw" {
  source           = "./modules/s3_raw"
  project          = var.project
  environment      = var.environment
  aws_region       = var.aws_region
  snowpipe_sqs_arn = var.snowpipe_sqs_arn
}

module "iam" {
  source                 = "./modules/iam"
  project                = var.project
  environment            = var.environment
  mwaa_bucket_arn        = module.s3.mwaa_bucket_arn
  raw_bucket_arn         = module.s3_raw.bucket_arn
  snowflake_account      = var.snowflake_account
  snowflake_user         = var.snowflake_user
  snowflake_password     = var.snowflake_password
  snowflake_role         = var.snowflake_role
  snowflake_warehouse    = var.snowflake_warehouse
  snowflake_database     = var.snowflake_database
  snowflake_schema       = var.snowflake_schema
  snowflake_iam_user_arn = var.snowflake_iam_user_arn
  snowflake_external_id  = var.snowflake_external_id
}

module "sqs_lambda" {
  source          = "./modules/sqs_lambda"
  project         = var.project
  environment     = var.environment
  raw_bucket_name = module.s3_raw.bucket_name
  raw_bucket_arn  = module.s3_raw.bucket_arn
}

module "airflow_ec2" {
  source                  = "./modules/airflow_ec2"
  project                 = var.project
  environment             = var.environment
  vpc_id                  = module.networking.vpc_id
  public_subnet_id        = module.networking.public_subnet_ids[0]
  instance_type           = var.airflow_instance_type
  airflow_execution_role  = module.iam.mwaa_execution_role_arn
  snowflake_secret_arn    = module.iam.snowflake_secret_arn
}