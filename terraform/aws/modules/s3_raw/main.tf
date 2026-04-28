data "aws_caller_identity" "current" {}

locals {
  bucket_name = "mdp-raw-landing-kk-${data.aws_caller_identity.current.account_id}-${var.aws_region}"
}

# ── Raw landing bucket ─────────────────────────────────────────
resource "aws_s3_bucket" "raw" {
  bucket = local.bucket_name

  # force_destroy is false — protect raw data from accidental deletion
  force_destroy = false

  tags = {
    Name        = "mdp-raw-landing"
    Project     = var.project
    Environment = var.environment
  }
}

resource "aws_s3_bucket_versioning" "raw" {
  bucket = aws_s3_bucket.raw.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "raw" {
  bucket = aws_s3_bucket.raw.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "raw" {
  bucket                  = aws_s3_bucket.raw.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── Snowpipe S3 event notifications ───────────────────────────
# All 6 notifications share a single Snowflake-managed SQS queue.
# Created only after the Snowpipe SQS ARN is known (Phase 3 apply).
# events/inventory/ is written by the SQS→Lambda consumer and triggers
# PIPE_INVENTORY_EVENTS automatically via this notification.
resource "aws_s3_bucket_notification" "snowpipe" {
  count  = var.snowpipe_sqs_arn != "" ? 1 : 0
  bucket = aws_s3_bucket.raw.id

  queue {
    id            = "snowpipe-products"
    queue_arn     = var.snowpipe_sqs_arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "reference/products/"
  }

  queue {
    id            = "snowpipe-locations"
    queue_arn     = var.snowpipe_sqs_arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "reference/locations/"
  }

  queue {
    id            = "snowpipe-suppliers"
    queue_arn     = var.snowpipe_sqs_arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "reference/suppliers/"
  }

  queue {
    id            = "snowpipe-purchase_orders"
    queue_arn     = var.snowpipe_sqs_arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "transactions/purchase_orders/"
  }

  queue {
    id            = "snowpipe-purchase_order_lines"
    queue_arn     = var.snowpipe_sqs_arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "transactions/purchase_order_lines/"
  }

  queue {
    id            = "snowpipe-inventory_events"
    queue_arn     = var.snowpipe_sqs_arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "events/inventory/"
  }
}
