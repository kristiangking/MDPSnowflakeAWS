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
  role              = "ACCOUNTADMIN"
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
  name           = "LOADING_WH"
  warehouse_size = "X-SMALL"
  auto_suspend   = 60
  auto_resume    = true
  comment        = "Used by Snowpipe and data loaders"

  lifecycle {
    ignore_changes = [enable_query_acceleration, query_acceleration_max_scale_factor]
  }
}

resource "snowflake_warehouse" "transform" {
  name           = "TRANSFORM_WH"
  warehouse_size = "SMALL"
  auto_suspend   = 120
  auto_resume    = true
  comment        = "Used by dbt transformations"

  lifecycle {
    ignore_changes = [enable_query_acceleration, query_acceleration_max_scale_factor]
  }
}

resource "snowflake_warehouse" "report" {
  name           = "REPORT_WH"
  warehouse_size = "X-SMALL"
  auto_suspend   = 60
  auto_resume    = true
  comment        = "Used by dashboards and analysts"

  lifecycle {
    ignore_changes = [enable_query_acceleration, query_acceleration_max_scale_factor]
  }
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
  privileges        = ["USAGE", "CREATE SCHEMA"]
  on_account_object {
    object_type = "DATABASE"
    object_name = snowflake_database.transform.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "transform_future_schemas_transformer" {
  account_role_name = snowflake_account_role.transformer.name
  privileges        = ["USAGE", "CREATE TABLE", "CREATE VIEW"]
  on_schema {
    future_schemas_in_database = snowflake_database.transform.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "transform_future_tables_transformer" {
  account_role_name = snowflake_account_role.transformer.name
  privileges        = ["SELECT", "INSERT", "UPDATE", "DELETE", "TRUNCATE"]
  on_schema_object {
    future {
      object_type_plural = "TABLES"
      in_database        = snowflake_database.transform.name
    }
  }
}

resource "snowflake_grant_privileges_to_account_role" "transform_future_views_transformer" {
  account_role_name = snowflake_account_role.transformer.name
  privileges        = ["SELECT"]
  on_schema_object {
    future {
      object_type_plural = "VIEWS"
      in_database        = snowflake_database.transform.name
    }
  }
}

# ── ANALYTICS database grants ──────────────────────────────────
resource "snowflake_grant_privileges_to_account_role" "analytics_usage_transformer" {
  account_role_name = snowflake_account_role.transformer.name
  privileges        = ["USAGE", "CREATE SCHEMA"]
  on_account_object {
    object_type = "DATABASE"
    object_name = snowflake_database.analytics.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "analytics_future_schemas_transformer" {
  account_role_name = snowflake_account_role.transformer.name
  privileges        = ["USAGE", "CREATE TABLE", "CREATE VIEW"]
  on_schema {
    future_schemas_in_database = snowflake_database.analytics.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "analytics_future_tables_transformer" {
  account_role_name = snowflake_account_role.transformer.name
  privileges        = ["SELECT", "INSERT", "UPDATE", "DELETE", "TRUNCATE"]
  on_schema_object {
    future {
      object_type_plural = "TABLES"
      in_database        = snowflake_database.analytics.name
    }
  }
}

resource "snowflake_grant_privileges_to_account_role" "analytics_future_views_transformer" {
  account_role_name = snowflake_account_role.transformer.name
  privileges        = ["SELECT"]
  on_schema_object {
    future {
      object_type_plural = "VIEWS"
      in_database        = snowflake_database.analytics.name
    }
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

# ── Storage Integration ────────────────────────────────────────
resource "snowflake_storage_integration" "s3_raw" {
  name                      = "S3_RAW_INTEGRATION"
  type                      = "EXTERNAL_STAGE"
  storage_provider          = "S3"
  enabled                   = true
  storage_allowed_locations = ["s3://mdp-raw-landing-kk-277385995606-ap-southeast-2/"]
  storage_aws_role_arn      = var.snowflake_iam_role_arn
  comment                   = "Allows Snowflake to read from the raw S3 landing bucket"
}

resource "snowflake_grant_privileges_to_account_role" "integration_usage_loader" {
  account_role_name = snowflake_account_role.loader.name
  privileges        = ["USAGE"]
  on_account_object {
    object_type = "INTEGRATION"
    object_name = snowflake_storage_integration.s3_raw.name
  }
}

# ── RAW.INVENTORY Schema ───────────────────────────────────────
resource "snowflake_schema" "inventory" {
  database = snowflake_database.raw.name
  name     = "INVENTORY"
  comment  = "Schema for raw inventory data loaded via Snowpipe"
}

resource "snowflake_grant_privileges_to_account_role" "inventory_schema_loader" {
  account_role_name = snowflake_account_role.loader.name
  privileges        = ["USAGE", "CREATE TABLE", "CREATE STAGE", "CREATE PIPE"]
  on_schema {
    schema_name = "${snowflake_database.raw.name}.${snowflake_schema.inventory.name}"
  }
}

resource "snowflake_grant_privileges_to_account_role" "inventory_schema_transformer" {
  account_role_name = snowflake_account_role.transformer.name
  privileges        = ["USAGE"]
  on_schema {
    schema_name = "${snowflake_database.raw.name}.${snowflake_schema.inventory.name}"
  }
}

# ── File Formats ───────────────────────────────────────────────
resource "snowflake_file_format" "csv_header" {
  name              = "CSV_HEADER_FORMAT"
  database          = snowflake_database.raw.name
  schema            = snowflake_schema.inventory.name
  format_type       = "CSV"
  skip_header       = 1
  field_optionally_enclosed_by = "\""
  comment           = "CSV with header row skipped — used by reference and transaction pipes"
}

resource "snowflake_file_format" "json_array" {
  name              = "JSON_ARRAY_FORMAT"
  database          = snowflake_database.raw.name
  schema            = snowflake_schema.inventory.name
  format_type       = "JSON"
  strip_outer_array = true
  comment           = "JSON with outer array stripped — used by the inventory events pipe"
}

# ── External Stage ─────────────────────────────────────────────
resource "snowflake_stage" "s3_raw" {
  name                = "S3_RAW_STAGE"
  database            = snowflake_database.raw.name
  schema              = snowflake_schema.inventory.name
  url                 = "s3://mdp-raw-landing-kk-277385995606-ap-southeast-2/"
  storage_integration = snowflake_storage_integration.s3_raw.name
  comment             = "External stage pointing at the raw S3 landing bucket root"
}

# ── RAW Tables ─────────────────────────────────────────────────
# NOTE: Column types must exactly match the existing Snowflake DDL.
# Before applying, run: SELECT GET_DDL('TABLE', 'RAW.INVENTORY.<TABLE>');
# If the plan shows unexpected column changes, abort and reconcile types first.

resource "snowflake_table" "products" {
  database = snowflake_database.raw.name
  schema   = snowflake_schema.inventory.name
  name     = "PRODUCTS"
  comment  = "Raw products reference data loaded via Snowpipe"

  lifecycle { prevent_destroy = true }

  column {
    name     = "PRODUCT_ID"
    type     = "VARCHAR(16777216)"
    nullable = false
  }
  column {
    name     = "SKU"
    type     = "VARCHAR(16777216)"
    nullable = true
  }
  column {
    name     = "NAME"
    type     = "VARCHAR(16777216)"
    nullable = true
  }
  column {
    name     = "CATEGORY"
    type     = "VARCHAR(16777216)"
    nullable = true
  }
  column {
    name     = "BRAND"
    type     = "VARCHAR(16777216)"
    nullable = true
  }
  column {
    name     = "SUPPLIER_ID"
    type     = "VARCHAR(16777216)"
    nullable = true
  }
  column {
    name     = "UNIT_COST"
    type     = "FLOAT"
    nullable = true
  }
  column {
    name     = "RRP"
    type     = "FLOAT"
    nullable = true
  }
  column {
    name     = "REORDER_POINT"
    type     = "NUMBER(38,0)"
    nullable = true
  }
  column {
    name     = "REORDER_QTY"
    type     = "NUMBER(38,0)"
    nullable = true
  }
  column {
    name     = "WEIGHT_KG"
    type     = "FLOAT"
    nullable = true
  }
  column {
    name     = "_LOADED_AT"
    type     = "TIMESTAMP_LTZ(9)"
    nullable = true
    default { expression = "CURRENT_TIMESTAMP()" }
  }
}

resource "snowflake_table" "locations" {
  database = snowflake_database.raw.name
  schema   = snowflake_schema.inventory.name
  name     = "LOCATIONS"
  comment  = "Raw locations reference data loaded via Snowpipe"

  lifecycle { prevent_destroy = true }

  column {
    name     = "LOCATION_ID"
    type     = "VARCHAR(16777216)"
    nullable = false
  }
  column {
    name     = "NAME"
    type     = "VARCHAR(16777216)"
    nullable = true
  }
  column {
    name     = "TYPE"
    type     = "VARCHAR(16777216)"
    nullable = true
  }
  column {
    name     = "CITY"
    type     = "VARCHAR(16777216)"
    nullable = true
  }
  column {
    name     = "STATE"
    type     = "VARCHAR(16777216)"
    nullable = true
  }
  column {
    name     = "_LOADED_AT"
    type     = "TIMESTAMP_LTZ(9)"
    nullable = true
  }
}

resource "snowflake_table" "suppliers" {
  database = snowflake_database.raw.name
  schema   = snowflake_schema.inventory.name
  name     = "SUPPLIERS"
  comment  = "Raw suppliers reference data loaded via Snowpipe"

  lifecycle { prevent_destroy = true }

  column {
    name     = "SUPPLIER_ID"
    type     = "VARCHAR(16777216)"
    nullable = false
  }
  column {
    name     = "NAME"
    type     = "VARCHAR(16777216)"
    nullable = true
  }
  column {
    name     = "LEAD_TIME_DAYS"
    type     = "NUMBER(38,0)"
    nullable = true
  }
  column {
    name     = "CONTACT_EMAIL"
    type     = "VARCHAR(16777216)"
    nullable = true
  }
  column {
    name     = "PAYMENT_TERMS"
    type     = "VARCHAR(16777216)"
    nullable = true
  }
  column {
    name     = "_LOADED_AT"
    type     = "TIMESTAMP_LTZ(9)"
    nullable = true
  }
}

resource "snowflake_table" "purchase_orders" {
  database = snowflake_database.raw.name
  schema   = snowflake_schema.inventory.name
  name     = "PURCHASE_ORDERS"
  comment  = "Raw purchase orders transactional data loaded via Snowpipe"

  lifecycle { prevent_destroy = true }

  column {
    name     = "PO_ID"
    type     = "VARCHAR(16777216)"
    nullable = false
  }
  column {
    name     = "SUPPLIER_ID"
    type     = "VARCHAR(16777216)"
    nullable = true
  }
  column {
    name     = "LOCATION_ID"
    type     = "VARCHAR(16777216)"
    nullable = true
  }
  column {
    name     = "STATUS"
    type     = "VARCHAR(16777216)"
    nullable = true
  }
  column {
    name     = "CREATED_AT"
    type     = "TIMESTAMP_NTZ(9)"
    nullable = true
  }
  column {
    name     = "EXPECTED_DELIVERY_DATE"
    type     = "DATE"
    nullable = true
  }
  column {
    name     = "ACTUAL_DELIVERY_DATE"
    type     = "DATE"
    nullable = true
  }
  column {
    name     = "TOTAL_VALUE"
    type     = "FLOAT"
    nullable = true
  }
  column {
    name     = "_LOADED_AT"
    type     = "TIMESTAMP_LTZ(9)"
    nullable = true
    default { expression = "CURRENT_TIMESTAMP()" }
  }
}

resource "snowflake_table" "purchase_order_lines" {
  database = snowflake_database.raw.name
  schema   = snowflake_schema.inventory.name
  name     = "PURCHASE_ORDER_LINES"
  comment  = "Raw purchase order lines transactional data loaded via Snowpipe"

  lifecycle { prevent_destroy = true }

  column {
    name     = "PO_LINE_ID"
    type     = "VARCHAR(16777216)"
    nullable = false
  }
  column {
    name     = "PO_ID"
    type     = "VARCHAR(16777216)"
    nullable = true
  }
  column {
    name     = "PRODUCT_ID"
    type     = "VARCHAR(16777216)"
    nullable = true
  }
  column {
    name     = "QTY_ORDERED"
    type     = "NUMBER(38,0)"
    nullable = true
  }
  column {
    name     = "QTY_RECEIVED"
    type     = "NUMBER(38,0)"
    nullable = true
  }
  column {
    name     = "UNIT_COST"
    type     = "FLOAT"
    nullable = true
  }
  column {
    name     = "LINE_TOTAL"
    type     = "FLOAT"
    nullable = true
  }
  column {
    name     = "_LOADED_AT"
    type     = "TIMESTAMP_LTZ(9)"
    nullable = true
    default { expression = "CURRENT_TIMESTAMP()" }
  }
}

resource "snowflake_table" "inventory_events" {
  database = snowflake_database.raw.name
  schema   = snowflake_schema.inventory.name
  name     = "INVENTORY_EVENTS"
  comment  = "Raw inventory events loaded via Snowpipe from JSON files in S3"

  lifecycle { prevent_destroy = true }

  column {
    name     = "EVENT_ID"
    type     = "VARCHAR(16777216)"
    nullable = false
  }
  column {
    name     = "EVENT_TYPE"
    type     = "VARCHAR(16777216)"
    nullable = true
  }
  column {
    name     = "PRODUCT_ID"
    type     = "VARCHAR(16777216)"
    nullable = true
  }
  column {
    name     = "LOCATION_ID"
    type     = "VARCHAR(16777216)"
    nullable = true
  }
  column {
    name     = "QTY_DELTA"
    type     = "NUMBER(38,0)"
    nullable = true
  }
  column {
    name     = "QTY_AFTER"
    type     = "NUMBER(38,0)"
    nullable = true
  }
  column {
    name     = "REFERENCE_ID"
    type     = "VARCHAR(16777216)"
    nullable = true
  }
  column {
    name     = "OCCURRED_AT"
    type     = "TIMESTAMP_NTZ(9)"
    nullable = true
  }
  column {
    name     = "_LOADED_AT"
    type     = "TIMESTAMP_LTZ(9)"
    nullable = true
    default { expression = "CURRENT_TIMESTAMP()" }
  }
}

# Grant SELECT on all existing RAW.INVENTORY tables to TRANSFORMER
resource "snowflake_grant_privileges_to_account_role" "raw_tables_transformer" {
  account_role_name = snowflake_account_role.transformer.name
  privileges        = ["SELECT"]
  on_schema_object {
    all {
      object_type_plural = "TABLES"
      in_schema          = "${snowflake_database.raw.name}.${snowflake_schema.inventory.name}"
    }
  }
}

# Grant SELECT on future RAW.INVENTORY tables to TRANSFORMER (covers tables created after the initial grant)
resource "snowflake_grant_privileges_to_account_role" "raw_future_tables_transformer" {
  account_role_name = snowflake_account_role.transformer.name
  privileges        = ["SELECT"]
  on_schema_object {
    future {
      object_type_plural = "TABLES"
      in_schema          = "${snowflake_database.raw.name}.${snowflake_schema.inventory.name}"
    }
  }
}

# ── Snowpipes ──────────────────────────────────────────────────
resource "snowflake_pipe" "products" {
  database    = snowflake_database.raw.name
  schema      = snowflake_schema.inventory.name
  name        = "PIPE_PRODUCTS"
  auto_ingest = true
  comment     = "Snowpipe — loads products CSV files from S3 reference/products/"

  depends_on = [snowflake_table.products, snowflake_stage.s3_raw, snowflake_file_format.csv_header]

  copy_statement = <<-SQL
    COPY INTO RAW.inventory.products (
        product_id, sku, name, category, brand, supplier_id,
        unit_cost, rrp, reorder_point, reorder_qty, weight_kg
      )
      FROM @RAW.inventory.s3_raw_stage/reference/products/
      FILE_FORMAT = (FORMAT_NAME = 'RAW.inventory.csv_header_format')
  SQL
}

resource "snowflake_pipe" "locations" {
  database    = snowflake_database.raw.name
  schema      = snowflake_schema.inventory.name
  name        = "PIPE_LOCATIONS"
  auto_ingest = true
  comment     = "Snowpipe — loads locations CSV files from S3 reference/locations/"

  depends_on = [snowflake_table.locations, snowflake_stage.s3_raw, snowflake_file_format.csv_header]

  copy_statement = <<-SQL
    COPY INTO RAW.inventory.locations (
        location_id, name, type, city, state
      )
      FROM @RAW.inventory.s3_raw_stage/reference/locations/
      FILE_FORMAT = (FORMAT_NAME = 'RAW.inventory.csv_header_format')
  SQL
}

resource "snowflake_pipe" "suppliers" {
  database    = snowflake_database.raw.name
  schema      = snowflake_schema.inventory.name
  name        = "PIPE_SUPPLIERS"
  auto_ingest = true
  comment     = "Snowpipe — loads suppliers CSV files from S3 reference/suppliers/"

  depends_on = [snowflake_table.suppliers, snowflake_stage.s3_raw, snowflake_file_format.csv_header]

  copy_statement = <<-SQL
    COPY INTO RAW.inventory.suppliers (
        supplier_id, name, lead_time_days, contact_email, payment_terms
      )
      FROM @RAW.inventory.s3_raw_stage/reference/suppliers/
      FILE_FORMAT = (FORMAT_NAME = 'RAW.inventory.csv_header_format')
  SQL
}

resource "snowflake_pipe" "purchase_orders" {
  database    = snowflake_database.raw.name
  schema      = snowflake_schema.inventory.name
  name        = "PIPE_PURCHASE_ORDERS"
  auto_ingest = true
  comment     = "Snowpipe — loads purchase orders CSV files from S3 transactions/purchase_orders/"

  depends_on = [snowflake_table.purchase_orders, snowflake_stage.s3_raw, snowflake_file_format.csv_header]

  copy_statement = <<-SQL
    COPY INTO RAW.inventory.purchase_orders (
        po_id, supplier_id, location_id, status,
        created_at, expected_delivery_date, actual_delivery_date, total_value
      )
      FROM @RAW.inventory.s3_raw_stage/transactions/purchase_orders/
      FILE_FORMAT = (FORMAT_NAME = 'RAW.inventory.csv_header_format')
  SQL
}

resource "snowflake_pipe" "purchase_order_lines" {
  database    = snowflake_database.raw.name
  schema      = snowflake_schema.inventory.name
  name        = "PIPE_PURCHASE_ORDER_LINES"
  auto_ingest = true
  comment     = "Snowpipe — loads purchase order lines CSV files from S3 transactions/purchase_order_lines/"

  depends_on = [snowflake_table.purchase_order_lines, snowflake_stage.s3_raw, snowflake_file_format.csv_header]

  copy_statement = <<-SQL
    COPY INTO RAW.inventory.purchase_order_lines (
        po_line_id, po_id, product_id,
        qty_ordered, qty_received, unit_cost, line_total
      )
      FROM @RAW.inventory.s3_raw_stage/transactions/purchase_order_lines/
      FILE_FORMAT = (FORMAT_NAME = 'RAW.inventory.csv_header_format')
  SQL
}

resource "snowflake_pipe" "inventory_events" {
  database    = snowflake_database.raw.name
  schema      = snowflake_schema.inventory.name
  name        = "PIPE_INVENTORY_EVENTS"
  auto_ingest = true
  comment     = "Snowpipe — loads inventory event JSON files from S3 events/inventory/"

  depends_on = [snowflake_table.inventory_events, snowflake_stage.s3_raw]

  copy_statement = <<-SQL
    COPY INTO RAW.inventory.inventory_events (
        event_id, event_type, product_id, location_id,
        qty_delta, qty_after, reference_id, occurred_at
      )
      FROM (
        SELECT
          $1:event_id::VARCHAR,
          $1:event_type::VARCHAR,
          $1:product_id::VARCHAR,
          $1:location_id::VARCHAR,
          $1:qty_delta::NUMBER,
          $1:qty_after::NUMBER,
          $1:reference_id::VARCHAR,
          $1:occurred_at::TIMESTAMP
        FROM @RAW.inventory.s3_raw_stage/events/inventory/
      )
      FILE_FORMAT = (FORMAT_NAME = 'RAW.inventory.json_array_format')
  SQL
}

# ── STREAMLIT_APPS Database ────────────────────────────────────
resource "snowflake_database" "streamlit_apps" {
  name    = "STREAMLIT_APPS"
  comment = "Hosts Snowflake Streamlit dashboard applications"
}

resource "snowflake_schema" "streamlit_inventory" {
  database = snowflake_database.streamlit_apps.name
  name     = "INVENTORY"
  comment  = "Inventory management Streamlit apps"
}

# Internal named stage — Streamlit files (streamlit_app.py, environment.yml)
# are uploaded here after apply via SnowSQL PUT (see README)
resource "snowflake_stage" "streamlit" {
  name     = "STREAMLIT_STAGE"
  database = snowflake_database.streamlit_apps.name
  schema   = snowflake_schema.streamlit_inventory.name
  comment  = "Internal stage hosting whitegoods inventory Streamlit app files"
}

# ── Streamlit app ──────────────────────────────────────────────
resource "snowflake_streamlit" "whitegoods_dashboard" {
  database        = snowflake_database.streamlit_apps.name
  schema          = snowflake_schema.streamlit_inventory.name
  name            = "WHITEGOODS_INVENTORY_DASHBOARD"
  stage           = "${snowflake_database.streamlit_apps.name}.${snowflake_schema.streamlit_inventory.name}.${snowflake_stage.streamlit.name}"
  main_file       = "streamlit_app.py"
  query_warehouse = snowflake_warehouse.report.name
  title           = "Whitegoods Inventory Dashboard"
  comment         = "Whitegoods inventory management dashboard — queries ANALYTICS.marts"
}

# ── STREAMLIT_APPS grants ──────────────────────────────────────
resource "snowflake_grant_privileges_to_account_role" "streamlit_apps_db_reporter" {
  account_role_name = snowflake_account_role.reporter.name
  privileges        = ["USAGE"]
  on_account_object {
    object_type = "DATABASE"
    object_name = snowflake_database.streamlit_apps.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "streamlit_apps_schema_reporter" {
  account_role_name = snowflake_account_role.reporter.name
  privileges        = ["USAGE"]
  on_schema {
    schema_name = "${snowflake_database.streamlit_apps.name}.${snowflake_schema.streamlit_inventory.name}"
  }
}

resource "snowflake_grant_privileges_to_account_role" "streamlit_usage_reporter" {
  account_role_name = snowflake_account_role.reporter.name
  privileges        = ["USAGE"]
  on_schema_object {
    object_type = "STREAMLIT"
    object_name = "${snowflake_database.streamlit_apps.name}.${snowflake_schema.streamlit_inventory.name}.${snowflake_streamlit.whitegoods_dashboard.name}"
  }
}

# ── ANALYTICS.MARTS grants for REPORTER ───────────────────────
# These grants require dbt to have run at least once (dbt creates the MARTS schema).
# Uncomment and apply AFTER running the dbt DAG in Airflow for the first time.
#
# resource "snowflake_grant_privileges_to_account_role" "analytics_marts_schema_reporter" {
#   account_role_name = snowflake_account_role.reporter.name
#   privileges        = ["USAGE"]
#   on_schema {
#     schema_name = "${snowflake_database.analytics.name}.MARTS"
#   }
# }
#
# resource "snowflake_grant_privileges_to_account_role" "analytics_marts_tables_reporter" {
#   account_role_name = snowflake_account_role.reporter.name
#   privileges        = ["SELECT"]
#   on_schema_object {
#     all {
#       object_type_plural = "TABLES"
#       in_schema          = "${snowflake_database.analytics.name}.MARTS"
#     }
#   }
# }
