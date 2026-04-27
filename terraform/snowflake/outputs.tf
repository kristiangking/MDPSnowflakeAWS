output "raw_database" {
  value = snowflake_database.raw.name
}

output "transform_database" {
  value = snowflake_database.transform.name
}

output "analytics_database" {
  value = snowflake_database.analytics.name
}

output "loader_role" {
  value = snowflake_role.loader.name
}

output "transformer_role" {
  value = snowflake_role.transformer.name
}

output "reporter_role" {
  value = snowflake_role.reporter.name
}
