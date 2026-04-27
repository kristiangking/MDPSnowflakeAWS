data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ── Snowflake storage integration IAM role ─────────────────────
# Phase 1: created with placeholder trust policy (default variable values)
# Phase 3: re-applied with real values from Snowflake terraform outputs
resource "aws_iam_role" "snowflake_s3" {
  name = "${var.project}-${var.environment}-snowflake-s3-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = var.snowflake_iam_user_arn
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
  }
}

resource "aws_iam_role_policy" "snowflake_s3" {
  name = "${var.project}-${var.environment}-snowflake-s3-policy"
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
          var.raw_bucket_arn,
          "${var.raw_bucket_arn}/*"
        ]
      }
    ]
  })
}

# ── Secrets Manager ────────────────────────────────────────────
resource "aws_secretsmanager_secret" "snowflake" {
  name                    = "${var.project}-${var.environment}-snowflake-creds"
  description             = "Snowflake credentials for dbt service account"
  recovery_window_in_days = 0

  tags = {
    Project     = var.project
    Environment = var.environment
  }
}

resource "aws_secretsmanager_secret_version" "snowflake" {
  secret_id = aws_secretsmanager_secret.snowflake.id
  secret_string = jsonencode({
    account   = var.snowflake_account
    user      = var.snowflake_user
    password  = var.snowflake_password
    role      = var.snowflake_role
    warehouse = var.snowflake_warehouse
    database  = var.snowflake_database
    schema    = var.snowflake_schema
  })
}

# MWAA execution role
resource "aws_iam_role" "mwaa_execution" {
  name = "${var.project}-${var.environment}-mwaa-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = [
            "airflow.amazonaws.com",
            "airflow-env.amazonaws.com"
          ]
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "mwaa_execution" {
  name = "${var.project}-${var.environment}-mwaa-execution-policy"
  role = aws_iam_role.mwaa_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:ListBucket",
          "s3:PutObject"
        ]
        Resource = [
          var.mwaa_bucket_arn,
          "${var.mwaa_bucket_arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:GetLogEvents",
          "logs:GetLogRecord",
          "logs:GetLogDelivery",
          "logs:ListLogDeliveries"
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:airflow-*"
      },
      {
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "sqs:ChangeMessageVisibility",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl",
          "sqs:ReceiveMessage",
          "sqs:SendMessage"
        ]
        Resource = "arn:aws:sqs:${data.aws_region.current.name}:*:airflow-celery-*"
      },
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = aws_secretsmanager_secret.snowflake.arn
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey",
          "kms:GenerateDataKey*",
          "kms:Encrypt"
        ]
        Resource = "*"
        Condition = {
          StringLike = {
            "kms:ViaService" = [
              "sqs.${data.aws_region.current.name}.amazonaws.com",
              "s3.${data.aws_region.current.name}.amazonaws.com"
            ]
          }
        }
      }
    ]
  })
}