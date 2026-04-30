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

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

module "s3_raw" {
  source           = "./modules/s3_raw"
  project          = var.project
  environment      = var.environment
  aws_region       = var.aws_region
  snowpipe_sqs_arn = var.snowpipe_sqs_arn
}

module "sqs_lambda" {
  source          = "./modules/sqs_lambda"
  project         = var.project
  environment     = var.environment
  raw_bucket_name = module.s3_raw.bucket_name
  raw_bucket_arn  = module.s3_raw.bucket_arn
}

# ── Snowflake S3 storage integration IAM role ──────────────────
# Owned by the data product because it grants access to the data
# product's raw S3 bucket and is paired with the data product's
# Snowflake storage integration.
#
# Phase 1: created with placeholder trust policy.
# Phase 2: re-applied after data product Snowflake writes
#          snowflake_iam_user_arn and snowflake_external_id to SSM.
resource "aws_iam_role" "snowflake_s3" {
  name = "${var.project}-${var.environment}-whitegoods-snowflake-s3-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = var.snowflake_iam_user_arn != "placeholder" ? var.snowflake_iam_user_arn : "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "sts:ExternalId" = var.snowflake_external_id
          }
        }
      }
    ]
  })

  tags = {
    Project     = var.project
    Environment = var.environment
    DataProduct = "whitegoods_inventory"
  }
}

resource "aws_iam_role_policy" "snowflake_s3" {
  name = "${var.project}-${var.environment}-whitegoods-snowflake-s3-policy"
  role = aws_iam_role.snowflake_s3.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          module.s3_raw.bucket_arn,
          "${module.s3_raw.bucket_arn}/*"
        ]
      }
    ]
  })
}

# ── DAG deployment to Airflow S3 bucket ────────────────────────
# Reads the Airflow S3 bucket name written by platform Terraform.
# Uploading here means data product owners can deploy their DAG
# by running this Terraform — no platform re-deployment needed.
# The EC2 cron job syncs from this prefix every minute.
data "aws_ssm_parameter" "airflow_s3_bucket" {
  name = "/mdp/platform/airflow_s3_bucket"
}

resource "aws_s3_object" "dag" {
  bucket = data.aws_ssm_parameter.airflow_s3_bucket.value
  key    = "dags/whitegoods_dbt_dag.py"
  source = "${path.module}/../../airflow/dags/whitegoods_dbt_dag.py"
  etag   = filemd5("${path.module}/../../airflow/dags/whitegoods_dbt_dag.py")
}

# ── SSM Parameter Store — data product AWS outputs ─────────────
# Written so the data product Snowflake Terraform can read the
# S3 role ARN without needing access to this module's state.
resource "aws_ssm_parameter" "snowflake_s3_role_arn" {
  name  = "/mdp/data_products/whitegoods_inventory/snowflake_s3_role_arn"
  type  = "String"
  value = aws_iam_role.snowflake_s3.arn

  tags = {
    Project     = var.project
    Environment = var.environment
    DataProduct = "whitegoods_inventory"
    ManagedBy   = "terraform-data-product"
  }
}

resource "aws_ssm_parameter" "raw_bucket_name" {
  name  = "/mdp/data_products/whitegoods_inventory/raw_bucket_name"
  type  = "String"
  value = module.s3_raw.bucket_name

  tags = {
    Project     = var.project
    Environment = var.environment
    DataProduct = "whitegoods_inventory"
    ManagedBy   = "terraform-data-product"
  }
}

resource "aws_ssm_parameter" "inventory_events_queue_url" {
  name  = "/mdp/data_products/whitegoods_inventory/inventory_events_queue_url"
  type  = "String"
  value = module.sqs_lambda.queue_url

  tags = {
    Project     = var.project
    Environment = var.environment
    DataProduct = "whitegoods_inventory"
    ManagedBy   = "terraform-data-product"
  }
}
