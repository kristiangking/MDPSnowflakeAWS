data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# ── Lambda execution role ──────────────────────────────────────
resource "aws_iam_role" "api_ingest_lambda" {
  name = "${var.project}-${var.environment}-api-ingest-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Project     = var.project
    Environment = var.environment
  }
}

resource "aws_iam_role_policy_attachment" "api_ingest_lambda_basic" {
  role       = aws_iam_role.api_ingest_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "api_ingest_lambda" {
  name = "${var.project}-${var.environment}-api-ingest-lambda"
  role = aws_iam_role.api_ingest_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Resolve any registered data product's raw bucket name from SSM.
        Sid      = "SSMReadDataProducts"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/mdp/data_products/*/raw_bucket_name"
      },
      {
        # Write events to any data product raw bucket.
        # The Lambda only writes to SSM-registered buckets — that lookup is the
        # security control. This permission is intentionally broad so the platform
        # module has no coupling to individual data product bucket names.
        Sid      = "S3WriteApiEvents"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "arn:aws:s3:::*"
      }
    ]
  })
}

# ── Lambda function ────────────────────────────────────────────
data "archive_file" "api_ingest_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/api_ingest.py"
  output_path = "${path.module}/api_ingest.zip"
}

resource "aws_lambda_function" "api_ingest" {
  function_name    = "${var.project}-${var.environment}-api-ingest"
  description      = "Receives HTTP POST events, resolves target bucket from SSM, writes JSON to S3 for Snowpipe ingestion"
  runtime          = "python3.12"
  handler          = "api_ingest.handler"
  role             = aws_iam_role.api_ingest_lambda.arn
  filename         = data.archive_file.api_ingest_zip.output_path
  source_code_hash = data.archive_file.api_ingest_zip.output_base64sha256
  timeout          = 30
  memory_size      = 128

  environment {
    variables = {
      AWS_REGION_NAME = var.aws_region
    }
  }

  tags = {
    Project     = var.project
    Environment = var.environment
  }
}

resource "aws_cloudwatch_log_group" "api_ingest" {
  name              = "/aws/lambda/${aws_lambda_function.api_ingest.function_name}"
  retention_in_days = 14

  tags = {
    Project     = var.project
    Environment = var.environment
  }
}

# ── API Gateway REST API ───────────────────────────────────────
resource "aws_api_gateway_rest_api" "api_ingest" {
  name        = "${var.project}-${var.environment}-api-ingest"
  description = "Platform event ingestion endpoint — POST JSON events on behalf of external systems"

  tags = {
    Project     = var.project
    Environment = var.environment
  }
}

resource "aws_api_gateway_resource" "events" {
  rest_api_id = aws_api_gateway_rest_api.api_ingest.id
  parent_id   = aws_api_gateway_rest_api.api_ingest.root_resource_id
  path_part   = "events"
}

resource "aws_api_gateway_method" "post_events" {
  rest_api_id      = aws_api_gateway_rest_api.api_ingest.id
  resource_id      = aws_api_gateway_resource.events.id
  http_method      = "POST"
  authorization    = "NONE"
  api_key_required = true  # enforced via usage plan below
}

resource "aws_api_gateway_integration" "lambda" {
  rest_api_id             = aws_api_gateway_rest_api.api_ingest.id
  resource_id             = aws_api_gateway_resource.events.id
  http_method             = aws_api_gateway_method.post_events.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.api_ingest.invoke_arn
}

resource "aws_api_gateway_method_response" "post_202" {
  rest_api_id = aws_api_gateway_rest_api.api_ingest.id
  resource_id = aws_api_gateway_resource.events.id
  http_method = aws_api_gateway_method.post_events.http_method
  status_code = "202"
}

resource "aws_api_gateway_deployment" "v1" {
  rest_api_id = aws_api_gateway_rest_api.api_ingest.id

  # Force redeployment when the API definition changes
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.events.id,
      aws_api_gateway_method.post_events.id,
      aws_api_gateway_integration.lambda.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    aws_api_gateway_method.post_events,
    aws_api_gateway_integration.lambda,
  ]
}

resource "aws_api_gateway_stage" "v1" {
  deployment_id = aws_api_gateway_deployment.v1.id
  rest_api_id   = aws_api_gateway_rest_api.api_ingest.id
  stage_name    = "v1"

  tags = {
    Project     = var.project
    Environment = var.environment
  }
}

# ── API key + usage plan ───────────────────────────────────────
# One default key ships with the platform. Additional keys (one per
# supplier/retailer) can be added here or via the AWS console.
resource "aws_api_gateway_api_key" "default" {
  name        = "${var.project}-${var.environment}-api-ingest-default"
  description = "Default platform API key — rotate regularly, issue per-supplier keys for production"
  enabled     = true
}

resource "aws_api_gateway_usage_plan" "default" {
  name        = "${var.project}-${var.environment}-api-ingest"
  description = "Default usage plan — 50 req/s, burst 100"

  api_stages {
    api_id = aws_api_gateway_rest_api.api_ingest.id
    stage  = aws_api_gateway_stage.v1.stage_name
  }

  throttle_settings {
    burst_limit = 100
    rate_limit  = 50
  }
}

resource "aws_api_gateway_usage_plan_key" "default" {
  key_id        = aws_api_gateway_api_key.default.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.default.id
}

# ── Lambda permission for API Gateway ─────────────────────────
resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api_ingest.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.api_ingest.execution_arn}/*/*"
}
