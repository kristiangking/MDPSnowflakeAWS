#!/bin/bash
set -e

# Update system
yum update -y
yum install -y docker cronie
systemctl enable --now docker
systemctl enable --now crond
usermod -aG docker ec2-user

# Install Docker Compose
curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
  -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# Add 4GB swap — DataHub (Elasticsearch + Kafka + ZooKeeper) is memory-intensive
fallocate -l 4G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

# ── DataHub directory structure ────────────────────────────────
mkdir -p /home/ec2-user/datahub/{recipes,dbt-artifacts}
chown -R ec2-user:ec2-user /home/ec2-user/datahub

# ── Download DataHub quickstart compose (without Neo4j) ────────
curl -fsSL \
  "https://raw.githubusercontent.com/datahub-project/datahub/master/docker/quickstart/docker-compose-without-neo4j.quickstart.yml" \
  -o /home/ec2-user/datahub/docker-compose.yml
chown ec2-user:ec2-user /home/ec2-user/datahub/docker-compose.yml

# ── Generate .env with required signing key ────────────────────
# Newer DataHub quickstart compose requires authentication.tokenService.signingKey
# to be explicitly provided — it no longer auto-generates one.
SIGNING_KEY=$(openssl rand -hex 32)
cat > /home/ec2-user/datahub/.env << ENVFILE
DATAHUB_TOKEN_SERVICE_SIGNING_KEY=${SIGNING_KEY}
ENVFILE
chown ec2-user:ec2-user /home/ec2-user/datahub/.env

# ── Compose override: inject signing key into upgrade + GMS ────
# The quickstart compose does not pass the signing key to datahub-upgrade
# by default. This override adds it so SystemUpdate can initialise
# the token service without failing.
cat > /home/ec2-user/datahub/docker-compose.override.yml << 'OVERRIDE'
services:
  datahub-upgrade:
    environment:
      - DATAHUB_TOKEN_SERVICE_SIGNING_KEY=${DATAHUB_TOKEN_SERVICE_SIGNING_KEY}
      - METADATA_SERVICE_AUTH_ENABLED=false
  datahub-gms:
    environment:
      - DATAHUB_TOKEN_SERVICE_SIGNING_KEY=${DATAHUB_TOKEN_SERVICE_SIGNING_KEY}
OVERRIDE
chown ec2-user:ec2-user /home/ec2-user/datahub/docker-compose.override.yml

# ── Pre-pull ingestion image ───────────────────────────────────
# acryldata/datahub-ingestion has all connectors pre-installed —
# avoids pip dependency hell on the host entirely.
docker pull acryldata/datahub-ingestion:head || true

# ── Pull DataHub images and start ──────────────────────────────
cd /home/ec2-user/datahub
sudo -u ec2-user docker-compose pull
# datahub-upgrade (schema migration) can fail on first boot if Elasticsearch
# isn't ready yet — it will restart and succeed once ES is healthy.
# || true prevents set -e from aborting the entire bootstrap.
sudo -u ec2-user docker-compose up -d || true

# ── Snowflake ingestion recipe ─────────────────────────────────
# Crawls WHITEGOODS_RAW/TRANSFORM/ANALYTICS every 6 hours.
# Uses TF_SERVICE_USER (ACCOUNTADMIN) for full database visibility.
# TODO: replace with a dedicated read-only DataHub role for hardening.
cat > /home/ec2-user/datahub/recipes/snowflake.yml << 'RECIPE'
source:
  type: snowflake
  config:
    account_id: ${snowflake_account}
    username: TF_SERVICE_USER
    password: "${snowflake_password}"
    role: ACCOUNTADMIN
    warehouse: WHITEGOODS_LOADING_WH
    database_pattern:
      allow:
        - "^WHITEGOODS_RAW$"
        - "^WHITEGOODS_TRANSFORM$"
        - "^WHITEGOODS_ANALYTICS$"
    schema_pattern:
      deny:
        - "^INFORMATION_SCHEMA$"
    include_table_lineage: true
    include_view_lineage: true
    profiling:
      enabled: false
sink:
  type: datahub-rest
  config:
    server: "http://localhost:8080"
RECIPE

# ── dbt ingestion recipe ───────────────────────────────────────
# Reads manifest.json + catalog.json synced from S3 by the cron.
# Produces model-level lineage: raw source -> staging -> intermediate -> mart.
cat > /home/ec2-user/datahub/recipes/dbt.yml << 'RECIPE'
source:
  type: dbt
  config:
    manifest_path: /dbt-artifacts/manifest.json
    catalog_path: /dbt-artifacts/catalog.json
    target_platform: snowflake
    target_platform_instance: ${snowflake_account}
    load_schemas: true
    load_ownership: true
sink:
  type: datahub-rest
  config:
    server: "http://localhost:8080"
RECIPE

# ── Airflow ingestion recipe ───────────────────────────────────
# Crawls Airflow REST API to surface DAG/task metadata in DataHub.
cat > /home/ec2-user/datahub/recipes/airflow.yml << RECIPE
source:
  type: airflow
  config:
    connection:
      conn_id: airflow_rest
      host: "http://${airflow_host}"
      port: 8080
      login: admin
      password: admin
    dag_filter_pattern:
      allow:
        - ".*"
sink:
  type: datahub-rest
  config:
    server: "http://localhost:8080"
RECIPE

chown -R ec2-user:ec2-user /home/ec2-user/datahub/recipes

# ── Ingestion cron ─────────────────────────────────────────────
# Runs ingestion via Docker — uses the pre-pulled acryldata/datahub-ingestion
# image which has all connectors pre-installed. No host pip install needed.
#
# dbt:      syncs artifacts from S3 then ingests at 20:30 UTC
#           (30 min after the Airflow dbt DAG runs at 20:00 UTC)
# Snowflake: full metadata crawl every 6 hours
# Airflow:   pipeline metadata every 6 hours
cat > /etc/cron.d/datahub-ingestion << CRON
30 20 * * * root aws s3 sync s3://${airflow_s3_bucket}/datahub/dbt/ /home/ec2-user/datahub/dbt-artifacts/ --region ap-southeast-2 && docker run --rm --network host -v /home/ec2-user/datahub/recipes:/recipes -v /home/ec2-user/datahub/dbt-artifacts:/dbt-artifacts acryldata/datahub-ingestion:head datahub ingest -c /recipes/dbt.yml 2>/dev/null || true
0 */6 * * * root docker run --rm --network host -v /home/ec2-user/datahub/recipes:/recipes acryldata/datahub-ingestion:head datahub ingest -c /recipes/snowflake.yml 2>/dev/null || true
0 */6 * * * root docker run --rm --network host -v /home/ec2-user/datahub/recipes:/recipes acryldata/datahub-ingestion:head datahub ingest -c /recipes/airflow.yml 2>/dev/null || true
CRON
chmod 644 /etc/cron.d/datahub-ingestion
