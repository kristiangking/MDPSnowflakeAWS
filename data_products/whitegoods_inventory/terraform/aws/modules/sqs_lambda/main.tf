data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# ── Dead-letter queue ──────────────────────────────────────────
resource "aws_sqs_queue" "dlq" {
  name                       = "inventory-events-dlq"
  visibility_timeout_seconds = 30
  message_retention_seconds  = 345600 # 4 days
  sqs_managed_sse_enabled    = true

  tags = {
    Project     = var.project
    Environment = var.environment
  }
}

# ── Main queue ─────────────────────────────────────────────────
resource "aws_sqs_queue" "main" {
  name                       = "inventory-events-queue"
  visibility_timeout_seconds = 30
  message_retention_seconds  = 345600 # 4 days
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3
  })

  tags = {
    Project     = var.project
    Environment = var.environment
  }
}

# ── Lambda execution role ──────────────────────────────────────
resource "aws_iam_role" "lambda_exec" {
  name = "${var.project}-${var.environment}-sqs-inventory-consumer-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Project     = var.project
    Environment = var.environment
  }
}

resource "aws_iam_role_policy" "lambda_sqs" {
  name = "${var.project}-${var.environment}-sqs-consumer-sqs-policy"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = aws_sqs_queue.main.arn
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_s3" {
  name = "${var.project}-${var.environment}-sqs-consumer-s3-policy"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${var.raw_bucket_arn}/events/inventory/*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# ── Lambda function ────────────────────────────────────────────
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.root}/../../lambda/sqs_inventory_consumer/lambda_function.py"
  output_path = "${path.module}/lambda_function.zip"
}

resource "aws_lambda_function" "consumer" {
  function_name    = "sqs-inventory-events-consumer"
  description      = "Reads inventory events from SQS, batches them, and writes JSON files to the raw S3 landing bucket"
  runtime          = "python3.12"
  handler          = "lambda_function.lambda_handler"
  role             = aws_iam_role.lambda_exec.arn
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = 30  # increased from 3s — s3:PutObject can take a few seconds
  memory_size      = 128

  environment {
    variables = {
      RAW_BUCKET = var.raw_bucket_name
    }
  }

  tags = {
    Project     = var.project
    Environment = var.environment
  }
}

# ── SQS → Lambda event source mapping ─────────────────────────
resource "aws_lambda_event_source_mapping" "sqs" {
  event_source_arn = aws_sqs_queue.main.arn
  function_name    = aws_lambda_function.consumer.arn
  batch_size       = 10
  enabled          = true
}
