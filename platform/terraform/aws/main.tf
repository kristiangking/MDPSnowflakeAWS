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

module "iam" {
  source              = "./modules/iam"
  project             = var.project
  environment         = var.environment
  mwaa_bucket_arn     = module.s3.mwaa_bucket_arn
  snowflake_account   = var.snowflake_account
  snowflake_user      = var.snowflake_user
  snowflake_password  = var.snowflake_password
  snowflake_role      = var.snowflake_role
  snowflake_warehouse = var.snowflake_warehouse
  snowflake_database  = var.snowflake_database
  snowflake_schema    = var.snowflake_schema
}

module "airflow_ec2" {
  source                 = "./modules/airflow_ec2"
  project                = var.project
  environment            = var.environment
  vpc_id                 = module.networking.vpc_id
  public_subnet_id       = module.networking.public_subnet_ids[0]
  instance_type          = var.airflow_instance_type
  airflow_execution_role = module.iam.mwaa_execution_role_arn
  snowflake_secret_arn   = module.iam.snowflake_secret_arn
  airflow_s3_bucket      = module.s3.mwaa_bucket_name
}

# ── SSM Parameter Store — platform outputs ─────────────────────
# Written here so data product teams can discover platform values
# without accessing Terraform state.
resource "aws_ssm_parameter" "airflow_public_ip" {
  name  = "/mdp/platform/airflow_public_ip"
  type  = "String"
  value = module.airflow_ec2.public_ip

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform-platform"
  }
}

resource "aws_ssm_parameter" "airflow_s3_bucket" {
  name  = "/mdp/platform/airflow_s3_bucket"
  type  = "String"
  value = module.s3.mwaa_bucket_name

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform-platform"
  }
}
