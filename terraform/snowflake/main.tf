terraform {
  required_providers {
    snowflake = {
      source  = "Snowflake-Labs/snowflake"
      version = "~> 0.98"
    }
  }
}

provider "snowflake" {
  account  = var.snowflake_account
  username = var.snowflake_user
  password = var.snowflake_password
  role     = "SYSADMIN"
}

# ── Databases ──────────────────────────────────────────────────
resource "snowflake_database" "raw" {
  name    = "RAW"
  comment = "Landing zone for all raw ingested data"
}

resource "snowflake_database" "transform" {
  name    = "TRANSFORM"
  comment = "dbt staging and intermediate models"
}

resource "snowflake_database" "analytics" {
  name    = "ANALYTICS"
  comment = "dbt mart models — source of truth for dashboards"
}

# ── Warehouses ─────────────────────────────────────────────────
resource "snowflake_warehouse" "load" {
  name           = "LOAD_WH"
  warehouse_size = "X-SMALL"
  auto_suspend   = 60
  auto_resume    = true
  comment        = "Used by Snowpipe and data loaders"
}

resource "snowflake_warehouse" "transform" {
  name           = "TRANSFORM_WH"
  warehouse_size = "X-SMALL"
  auto_suspend   = 60
  auto_resume    = true
  comment        = "Used by dbt transformations"
}

resource "snowflake_warehouse" "report" {
  name           = "REPORT_WH"
  warehouse_size = "X-SMALL"
  auto_suspend   = 60
  auto_resume    = true
  comment        = "Used by dashboards and analysts"
}

# ── Roles ──────────────────────────────────────────────────────
resource "snowflake_role" "loader" {
  name    = "LOADER"
  comment = "Used by Snowpipe and ingestion processes"
}

resource "snowflake_role" "transformer" {
  name    = "TRANSFORMER"
  comment = "Used by dbt to run transformations"
}

resource "snowflake_role" "reporter" {
  name    = "REPORTER"
  comment = "Used by dashboards and Streamlit apps"
}

# ── Role hierarchy ─────────────────────────────────────────────
resource "snowflake_role_grants" "loader_to_sysadmin" {
  role_name = snowflake_role.loader.name
  roles     = ["SYSADMIN"]
}

resource "snowflake_role_grants" "transformer_to_sysadmin" {
  role_name = snowflake_role.transformer.name
  roles     = ["SYSADMIN"]
}

resource "snowflake_role_grants" "reporter_to_sysadmin" {
  role_name = snowflake_role.reporter.name
  roles     = ["SYSADMIN"]
}

# ── Service user ───────────────────────────────────────────────
resource "snowflake_user" "dbt_service_user" {
  name         = "dbt_service_user"
  password     = var.dbt_service_password
  default_role = snowflake_role.transformer.name
  must_change_password = false
  comment      = "Service account for dbt — no MFA"
}

resource "snowflake_role_grants" "transformer_to_dbt_user" {
  role_name = snowflake_role.transformer.name
  users     = [snowflake_user.dbt_service_user.name]
}

# ── RAW database grants ────────────────────────────────────────
resource "snowflake_database_grant" "raw_loader" {
  database_name = snowflake_database.raw.name
  privilege     = "USAGE"
  roles         = [snowflake_role.loader.name]
}

resource "snowflake_database_grant" "raw_transformer" {
  database_name = snowflake_database.raw.name
  privilege     = "USAGE"
  roles         = [snowflake_role.transformer.name]
}

# ── TRANSFORM database grants ──────────────────────────────────
resource "snowflake_database_grant" "transform_transformer" {
  database_name = snowflake_database.transform.name
  privilege     = "USAGE"
  roles         = [snowflake_role.transformer.name]
}

# ── ANALYTICS database grants ──────────────────────────────────
resource "snowflake_database_grant" "analytics_transformer" {
  database_name = snowflake_database.analytics.name
  privilege     = "USAGE"
  roles         = [snowflake_role.transformer.name]
}

resource "snowflake_database_grant" "analytics_reporter" {
  database_name = snowflake_database.analytics.name
  privilege     = "USAGE"
  roles         = [snowflake_role.reporter.name]
}

# ── Warehouse grants ───────────────────────────────────────────
resource "snowflake_warehouse_grant" "load_wh_loader" {
  warehouse_name = snowflake_warehouse.load.name
  privilege      = "USAGE"
  roles          = [snowflake_role.loader.name]
}

resource "snowflake_warehouse_grant" "transform_wh_transformer" {
  warehouse_name = snowflake_warehouse.transform.name
  privilege      = "USAGE"
  roles          = [snowflake_role.transformer.name]
}

resource "snowflake_warehouse_grant" "report_wh_reporter" {
  warehouse_name = snowflake_warehouse.report.name
  privilege      = "USAGE"
  roles          = [snowflake_role.reporter.name]
}
