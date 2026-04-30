output "dbt_service_user" {
  value = snowflake_user.dbt_service.name
}
