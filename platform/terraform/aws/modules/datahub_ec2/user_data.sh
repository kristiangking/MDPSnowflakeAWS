#!/bin/bash
set -e

# Update system
yum update -y
yum install -y docker python3-pip python3-devel gcc cronie git
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

# ── Install DataHub CLI + ingestion connectors ─────────────────
pip3 install \
  'acryl-datahub' \
  'acryl-datahub[snowflake]' \
  'acryl-datahub[dbt-core]'

# ── DataHub directory structure ────────────────────────────────
mkdir -p /home/ec2-user/datahub/{recipes,dbt-artifacts}
chown -R ec2-user:ec2-user /home/ec2-user/datahub

# ── Download DataHub quickstart compose (without Neo4j) ────────
# Uses the lighter quickstart variant — no graph DB dependency.
curl -fsSL \
  "https://raw.githubusercontent.com/datahub-project/datahub/master/docker/quickstart/docker-compose-without-neo4j.quickstart.yml" \
  -o /home/ec2-user/datahub/docker-compose.yml

chown ec2-user:ec2-user /home/ec2-user/datahub/docker-compose.yml

# ── Pull images and start DataHub ──────────────────────────────
cd /home/ec2-user/datahub
sudo -u ec2-user docker-compose pull
sudo -u ec2-user docker-compose up -d

# ── Snowflake ingestion recipe ─────────────────────────────────
# Crawls all WHITEGOODS_* databases: schemas, tables, columns.
# Uses TF_SERVICE_USER (ACCOUNTADMIN) for full visibility.
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
        - "^WHITEGOODS_RAW$$"
        - "^WHITEGOODS_TRANSFORM$$"
        - "^WHITEGOODS_ANALYTICS$$"
    schema_pattern:
      deny:
        - "^INFORMATION_SCHEMA$$"
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
# Reads manifest.json + catalog.json synced from S3.
# Produces model-level lineage: raw source → staging → intermediate → mart.
cat > /home/ec2-user/datahub/recipes/dbt.yml << 'RECIPE'
source:
  type: dbt
  config:
    manifest_path: /home/ec2-user/datahub/dbt-artifacts/manifest.json
    catalog_path: /home/ec2-user/datahub/dbt-artifacts/catalog.json
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
# dbt:      syncs artifacts from S3 then ingests at 20:30 UTC
#           (30 min after the Airflow dbt DAG runs at 20:00 UTC)
# Snowflake: full metadata crawl every 6 hours
# Airflow:   pipeline metadata every 6 hours
cat > /etc/cron.d/datahub-ingestion << CRON
30 20 * * * root aws s3 sync s3://${airflow_s3_bucket}/datahub/dbt/ /home/ec2-user/datahub/dbt-artifacts/ --region ap-southeast-2 && /usr/local/bin/datahub ingest -c /home/ec2-user/datahub/recipes/dbt.yml 2>/dev/null || true
0 */6 * * * root /usr/local/bin/datahub ingest -c /home/ec2-user/datahub/recipes/snowflake.yml 2>/dev/null || true
0 */6 * * * root /usr/local/bin/datahub ingest -c /home/ec2-user/datahub/recipes/airflow.yml 2>/dev/null || true
CRON
chmod 644 /etc/cron.d/datahub-ingestion
