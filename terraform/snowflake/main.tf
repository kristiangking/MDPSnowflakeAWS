terraform {
  required_providers {
    snowflake = {
      source  = "snowflakedb/snowflake"
      version = "~> 0.98"
    }
  }
}

provider "snowflake" {
  organization_name = split("-", var.snowflake_account)[0]
  account_name      = split("-", var.snowflake_account)[1]
  user              = var.snowflake_user
  password          = var.snowflake_password
  role              = "SYSADMIN"
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
resource "snowflake_warehouse" "loading" {
  name                      = "LOADING_WH"
  warehouse_size            = "X-SMALL"
  auto_suspend              = 60
  auto_resume               = true
  enable_query_acceleration = false
  comment                   = "Used by Snowpipe and data loaders"
}

resource "snowflake_warehouse" "transform" {
  name                      = "TRANSFORM_WH"
  warehouse_size            = "SMALL"
  auto_suspend              = 120
  auto_resume               = true
  enable_query_acceleration = false
  comment                   = "Used by dbt transformations"
}

resource "snowflake_warehouse" "report" {
  name           = "REPORT_WH"
  warehouse_size = "X-SMALL"
  auto_suspend   = 60
  auto_resume    = true
  comment        = "Used by dashboards and analysts"
}

# ── Roles ──────────────────────────────────────────────────────
resource "snowflake_account_role" "loader" {
  name    = "LOADER"
  comment = "Used by Snowpipe and ingestion processes"
}

resource "snowflake_account_role" "transformer" {
  name    = "TRANSFORMER"
  comment = "Used by dbt to run transformations"
}

resource "snowflake_account_role" "reporter" {
  name    = "REPORTER"
  comment = "Used by dashboards and Streamlit apps"
}

# ── Role hierarchy — grant custom roles up to SYSADMIN ─────────
resource "snowflake_grant_account_role" "loader_to_sysadmin" {
  role_name        = snowflake_account_role.loader.name
  parent_role_name = "SYSADMIN"
}

resource "snowflake_grant_account_role" "transformer_to_sysadmin" {
  role_name        = snowflake_account_role.transformer.name
  parent_role_name = "SYSADMIN"
}

resource "snowflake_grant_account_role" "reporter_to_sysadmin" {
  role_name        = snowflake_account_role.reporter.name
  parent_role_name = "SYSADMIN"
}

# ── Service user ───────────────────────────────────────────────
resource "snowflake_user" "dbt_service_user" {
  name                 = "DBT_SERVICE_USER"
  password             = var.dbt_service_password
  default_role         = snowflake_account_role.transformer.name
  must_change_password = false
  comment              = "Service account for dbt — no MFA"
}

resource "snowflake_grant_account_role" "transformer_to_dbt_user" {
  role_name = snowflake_account_role.transformer.name
  user_name = snowflake_user.dbt_service_user.name
}

# ── RAW database grants ────────────────────────────────────────
resource "snowflake_grant_privileges_to_account_role" "raw_usage_loader" {
  account_role_name = snowflake_account_role.loader.name
  privileges = ["USAGE"]
  on_account_object {
    object_type = "DATABASE"
    object_name = snowflake_database.raw.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "raw_usage_transformer" {
  account_role_name = snowflake_account_role.transformer.name
  privileges = ["USAGE"]
  on_account_object {
    object_type = "DATABASE"
    object_name = snowflake_database.raw.name
  }
}

# ── TRANSFORM database grants ──────────────────────────────────
resource "snowflake_grant_privileges_to_account_role" "transform_usage_transformer" {
  account_role_name = snowflake_account_role.transformer.name
  privileges = ["USAGE"]
  on_account_object {
    object_type = "DATABASE"
    object_name = snowflake_database.transform.name
  }
}

# ── ANALYTICS database grants ──────────────────────────────────
resource "snowflake_grant_privileges_to_account_role" "analytics_usage_transformer" {
  account_role_name = snowflake_account_role.transformer.name
  privileges = ["USAGE"]
  on_account_object {
    object_type = "DATABASE"
    object_name = snowflake_database.analytics.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "analytics_usage_reporter" {
  account_role_name = snowflake_account_role.reporter.name
  privileges = ["USAGE"]
  on_account_object {
    object_type = "DATABASE"
    object_name = snowflake_database.analytics.name
  }
}

# ── Warehouse grants ───────────────────────────────────────────
resource "snowflake_grant_privileges_to_account_role" "load_wh_loader" {
  account_role_name = snowflake_account_role.loader.name
  privileges = ["USAGE"]
  on_account_object {
    object_type = "WAREHOUSE"
    object_name = snowflake_warehouse.loading.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "transform_wh_transformer" {
  account_role_name = snowflake_account_role.transformer.name
  privileges = ["USAGE"]
  on_account_object {
    object_type = "WAREHOUSE"
    object_name = snowflake_warehouse.transform.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "report_wh_reporter" {
  account_role_name = snowflake_account_role.reporter.name
  privileges = ["USAGE"]
  on_account_object {
    object_type = "WAREHOUSE"
    object_name = snowflake_warehouse.report.name
  }
}
