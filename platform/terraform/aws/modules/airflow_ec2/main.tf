data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "image-id"
    values = ["ami-098341ffb8b768450"]
  }
}

resource "aws_key_pair" "airflow" {
  key_name   = "${var.project}-${var.environment}-airflow-key"
  public_key = file("~/.ssh/id_rsa.pub")
}

resource "aws_security_group" "airflow" {
  name        = "${var.project}-${var.environment}-airflow-sg"
  description = "Security group for Airflow EC2 instance"
  vpc_id      = var.vpc_id

  ingress {
    description = "Airflow UI"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
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
    Name        = "${var.project}-${var.environment}-airflow-sg"
    Project     = var.project
    Environment = var.environment
  }
}

resource "aws_iam_instance_profile" "airflow" {
  name = "${var.project}-${var.environment}-airflow-profile"
  role = split("/", var.airflow_execution_role)[1]
}

resource "aws_instance" "airflow" {
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = var.instance_type
  subnet_id                   = var.public_subnet_id
  vpc_security_group_ids      = [aws_security_group.airflow.id]
  key_name                    = aws_key_pair.airflow.key_name
  iam_instance_profile        = aws_iam_instance_profile.airflow.name
  associate_public_ip_address = true

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  user_data = templatefile("${path.module}/user_data.sh", {
    airflow_s3_bucket = var.airflow_s3_bucket
  })
  user_data_replace_on_change = true

  tags = {
    Name        = "${var.project}-${var.environment}-airflow"
    Project     = var.project
    Environment = var.environment
  }
}