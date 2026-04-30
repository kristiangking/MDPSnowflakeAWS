data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "image-id"
    values = ["ami-098341ffb8b768450"]
  }
}

# ── IAM role for DataHub EC2 ───────────────────────────────────
# Needs S3 read access to the Airflow bucket (dbt artifact sync).
# NOTE: Uses TF_SERVICE_USER credentials for Snowflake ingestion (ACCOUNTADMIN).
# Future hardening: create a dedicated DataHub read-only Snowflake role.
resource "aws_iam_role" "datahub" {
  name = "${var.project}-${var.environment}-datahub-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Project     = var.project
    Environment = var.environment
  }
}

resource "aws_iam_role_policy" "datahub" {
  name = "${var.project}-${var.environment}-datahub-policy"
  role = aws_iam_role.datahub.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Read dbt artifacts uploaded by the Airflow DAG
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::${var.airflow_s3_bucket}",
          "arn:aws:s3:::${var.airflow_s3_bucket}/*"
        ]
      },
      {
        # SSM reads for discoverability
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = "arn:aws:ssm:*:*:parameter/mdp/*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "datahub" {
  name = "${var.project}-${var.environment}-datahub-profile"
  role = aws_iam_role.datahub.name
}

# ── Key pair ───────────────────────────────────────────────────
resource "aws_key_pair" "datahub" {
  key_name   = "${var.project}-${var.environment}-datahub-key"
  public_key = file("~/.ssh/id_rsa.pub")
}

# ── Security group ─────────────────────────────────────────────
resource "aws_security_group" "datahub" {
  name        = "${var.project}-${var.environment}-datahub-sg"
  description = "Security group for DataHub EC2 instance"
  vpc_id      = var.vpc_id

  ingress {
    description = "DataHub UI"
    from_port   = 9002
    to_port     = 9002
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "DataHub GMS API (internal — Airflow plugin + ingestion CLI)"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.project}-${var.environment}-datahub-sg"
    Project     = var.project
    Environment = var.environment
  }
}

# ── EC2 instance ───────────────────────────────────────────────
resource "aws_instance" "datahub" {
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = var.instance_type
  subnet_id                   = var.public_subnet_id
  vpc_security_group_ids      = [aws_security_group.datahub.id]
  key_name                    = aws_key_pair.datahub.key_name
  iam_instance_profile        = aws_iam_instance_profile.datahub.name
  associate_public_ip_address = true

  root_block_device {
    volume_size = 50 # Elasticsearch index needs headroom
    volume_type = "gp3"
  }

  user_data = templatefile("${path.module}/user_data.sh", {
    airflow_s3_bucket  = var.airflow_s3_bucket
    snowflake_account  = var.snowflake_account
    snowflake_password = var.snowflake_password
    airflow_host       = var.airflow_host
  })
  user_data_replace_on_change = true

  tags = {
    Name        = "${var.project}-${var.environment}-datahub"
    Project     = var.project
    Environment = var.environment
  }
}
