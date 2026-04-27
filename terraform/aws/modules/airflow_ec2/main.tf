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

  user_data = <<-EOF
    #!/bin/bash
    set -e

    # Update system
    yum update -y
    yum install -y git python3-pip python3-devel gcc

    # Install Docker
    yum install -y docker
    systemctl start docker
    systemctl enable docker
    usermod -aG docker ec2-user

    # Install Docker Compose
    curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose

    # Install dbt
    pip3 install dbt-snowflake

    # Create Airflow directory structure
    mkdir -p /home/ec2-user/airflow/{dags,logs,plugins}

    # Airflow container runs as UID 50000 — set ownership so it can write logs
    chown -R 50000:0 /home/ec2-user/airflow/logs \
                     /home/ec2-user/airflow/dags \
                     /home/ec2-user/airflow/plugins
    chmod -R 775 /home/ec2-user/airflow/logs \
                 /home/ec2-user/airflow/dags \
                 /home/ec2-user/airflow/plugins

    # .env tells compose the UID to use for the airflow user inside containers
    cat > /home/ec2-user/airflow/.env << 'ENVFILE'
AIRFLOW_UID=50000
ENVFILE

    # Create Docker Compose file
    cat > /home/ec2-user/airflow/docker-compose.yml << 'COMPOSE'
services:
  postgres:
    image: postgres:13
    environment:
      POSTGRES_USER: airflow
      POSTGRES_PASSWORD: airflow
      POSTGRES_DB: airflow
    volumes:
      - postgres_data:/var/lib/postgresql/data
    restart: always

  airflow-init:
    image: apache/airflow:2.10.3
    user: "50000:0"
    depends_on:
      - postgres
    environment:
      AIRFLOW__CORE__EXECUTOR: LocalExecutor
      AIRFLOW__DATABASE__SQL_ALCHEMY_CONN: postgresql+psycopg2://airflow:airflow@postgres/airflow
      AIRFLOW__CORE__FERNET_KEY: ''
      AIRFLOW__CORE__LOAD_EXAMPLES: 'false'
    volumes:
      - ./dags:/opt/airflow/dags
      - ./logs:/opt/airflow/logs
      - ./plugins:/opt/airflow/plugins
    entrypoint: /bin/bash
    command: -c "airflow db migrate && airflow users create --username admin --password admin --firstname Admin --lastname User --role Admin --email admin@example.com || true"

  webserver:
    image: apache/airflow:2.10.3
    user: "50000:0"
    depends_on:
      - postgres
    environment:
      AIRFLOW__CORE__EXECUTOR: LocalExecutor
      AIRFLOW__DATABASE__SQL_ALCHEMY_CONN: postgresql+psycopg2://airflow:airflow@postgres/airflow
      AIRFLOW__CORE__FERNET_KEY: ''
      AIRFLOW__CORE__LOAD_EXAMPLES: 'false'
      AIRFLOW__WEBSERVER__DEFAULT_UI_TIMEZONE: Australia/Sydney
    volumes:
      - ./dags:/opt/airflow/dags
      - ./logs:/opt/airflow/logs
      - ./plugins:/opt/airflow/plugins
    ports:
      - "8080:8080"
    command: webserver
    restart: always
    healthcheck:
      test: ["CMD", "curl", "--fail", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 5

  scheduler:
    image: apache/airflow:2.10.3
    user: "50000:0"
    depends_on:
      - postgres
    environment:
      AIRFLOW__CORE__EXECUTOR: LocalExecutor
      AIRFLOW__DATABASE__SQL_ALCHEMY_CONN: postgresql+psycopg2://airflow:airflow@postgres/airflow
      AIRFLOW__CORE__FERNET_KEY: ''
      AIRFLOW__CORE__LOAD_EXAMPLES: 'false'
    volumes:
      - ./dags:/opt/airflow/dags
      - ./logs:/opt/airflow/logs
      - ./plugins:/opt/airflow/plugins
    command: scheduler
    restart: always

volumes:
  postgres_data:
COMPOSE

    chown ec2-user:ec2-user /home/ec2-user/airflow/docker-compose.yml \
                             /home/ec2-user/airflow/.env

    # Initialise and start Airflow
    cd /home/ec2-user/airflow
    sudo -u ec2-user docker-compose up airflow-init
    sudo -u ec2-user docker-compose up -d webserver scheduler
  EOF

  tags = {
    Name        = "${var.project}-${var.environment}-airflow"
    Project     = var.project
    Environment = var.environment
  }
}