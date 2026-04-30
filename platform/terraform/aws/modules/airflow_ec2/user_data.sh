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

# Add 2GB swap to prevent OOM on t3.small
fallocate -l 2G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

# Clone the repo
git clone https://github.com/kristiangking/MDPSnowflakeAWS.git /home/ec2-user/MDPSnowflakeAWS
chown -R ec2-user:ec2-user /home/ec2-user/MDPSnowflakeAWS

# Write dbt profiles.yml (credentials injected via Secrets Manager at runtime — hardcoded here for bootstrap)
mkdir -p /home/ec2-user/.dbt
cat > /home/ec2-user/.dbt/profiles.yml << 'PROFILES'
whitegoods_inventory:
  target: dev
  outputs:
    dev:
      type: snowflake
      account: ZKWOWXY-BB01746
      user: dbt_service_user
      password: DbtService2025!
      role: WHITEGOODS_TRANSFORMER
      warehouse: WHITEGOODS_TRANSFORM_WH
      database: WHITEGOODS_TRANSFORM
      schema: staging
      threads: 4
PROFILES
chown -R 50000:0 /home/ec2-user/.dbt
chmod 644 /home/ec2-user/.dbt/profiles.yml

# Fix dbt writable directory permissions for UID 50000 (Airflow container user)
mkdir -p /home/ec2-user/MDPSnowflakeAWS/data_products/whitegoods_inventory/dbt/whitegoods_inventory/{target,logs,dbt_packages}
chown -R 50000:0 \
  /home/ec2-user/MDPSnowflakeAWS/data_products/whitegoods_inventory/dbt/whitegoods_inventory/target \
  /home/ec2-user/MDPSnowflakeAWS/data_products/whitegoods_inventory/dbt/whitegoods_inventory/logs \
  /home/ec2-user/MDPSnowflakeAWS/data_products/whitegoods_inventory/dbt/whitegoods_inventory/dbt_packages
chmod -R 775 \
  /home/ec2-user/MDPSnowflakeAWS/data_products/whitegoods_inventory/dbt/whitegoods_inventory/target \
  /home/ec2-user/MDPSnowflakeAWS/data_products/whitegoods_inventory/dbt/whitegoods_inventory/logs \
  /home/ec2-user/MDPSnowflakeAWS/data_products/whitegoods_inventory/dbt/whitegoods_inventory/dbt_packages

# Create Airflow directory structure
mkdir -p /home/ec2-user/airflow/{dags,logs,plugins}

# Airflow container runs as UID 50000 — set ownership so it can write logs
chown -R 50000:0 /home/ec2-user/airflow/logs \
                 /home/ec2-user/airflow/dags \
                 /home/ec2-user/airflow/plugins
chmod -R 775 /home/ec2-user/airflow/logs \
             /home/ec2-user/airflow/dags \
             /home/ec2-user/airflow/plugins

# Copy DAG from repo into Airflow dags folder
cp /home/ec2-user/MDPSnowflakeAWS/data_products/whitegoods_inventory/airflow/dags/whitegoods_dbt_dag.py \
   /home/ec2-user/airflow/dags/
chown 50000:0 /home/ec2-user/airflow/dags/whitegoods_dbt_dag.py

# .env tells compose the UID to use for the airflow user inside containers
cat > /home/ec2-user/airflow/.env << 'ENVFILE'
AIRFLOW_UID=50000
ENVFILE

# Create a custom Airflow image with dbt-snowflake baked in
cat > /home/ec2-user/airflow/Dockerfile << 'DOCKERFILE'
FROM apache/airflow:2.10.3
RUN pip install dbt-snowflake
DOCKERFILE

# Build the custom image
docker build -t airflow-dbt:2.10.3 /home/ec2-user/airflow/

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
    image: airflow-dbt:2.10.3
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
      - /home/ec2-user/MDPSnowflakeAWS/data_products/whitegoods_inventory/dbt/whitegoods_inventory:/opt/airflow/dbt/whitegoods_inventory
      - /home/ec2-user/.dbt:/home/airflow/.dbt
    entrypoint: /bin/bash
    command: -c "airflow db migrate && airflow users create --username admin --password admin --firstname Admin --lastname User --role Admin --email admin@example.com || true"

  webserver:
    image: airflow-dbt:2.10.3
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
      - /home/ec2-user/MDPSnowflakeAWS/data_products/whitegoods_inventory/dbt/whitegoods_inventory:/opt/airflow/dbt/whitegoods_inventory
      - /home/ec2-user/.dbt:/home/airflow/.dbt
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
    image: airflow-dbt:2.10.3
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
      - /home/ec2-user/MDPSnowflakeAWS/data_products/whitegoods_inventory/dbt/whitegoods_inventory:/opt/airflow/dbt/whitegoods_inventory
      - /home/ec2-user/.dbt:/home/airflow/.dbt
    command: scheduler
    restart: always

volumes:
  postgres_data:
COMPOSE

chown ec2-user:ec2-user /home/ec2-user/airflow/docker-compose.yml \
                         /home/ec2-user/airflow/.env \
                         /home/ec2-user/airflow/Dockerfile

# Initialise and start Airflow
cd /home/ec2-user/airflow
sudo -u ec2-user docker-compose up airflow-init
sudo -u ec2-user docker-compose up -d webserver scheduler
