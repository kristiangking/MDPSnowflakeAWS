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
  role     = "ACCOUNTADMIN"
}

# ── dbt service account ────────────────────────────────────────
# This user is shared infrastructure — it is the credential Airflow
# uses to run dbt against Snowflake. Role grants are managed by each
# data product's Terraform (the data product grants its TRANSFORMER
# role to this user).
resource "snowflake_user" "dbt_service" {
  name         = "dbt_service_user"
  password     = var.dbt_service_password
  default_role = "PUBLIC"
  comment      = "Service account for dbt Core transformations — managed by platform Terraform"

  lifecycle {
    ignore_changes = [password]
  }
}
