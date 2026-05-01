/*
  mart_gx_validation_trends
  ─────────────────────────
  One row per individual expectation result per checkpoint run, enriched with
  rolling trend metrics. Intended for data quality dashboards showing how
  validation pass rates and failure counts change over time.

  Grain: run_id + suite_name + expectation_type + column_name
*/

with validations as (
    select * from {{ ref('stg_gx_validations') }}
),

enriched as (
    select
        run_id,
        run_time::date                                              as run_date,
        checkpoint_name,
        suite_name,
        data_asset_name,
        expectation_type,
        column_name,
        success,
        observed_value,
        unexpected_count,
        unexpected_percent,
        run_time,

        -- Rolling failure count over the last 7 runs for this specific check
        -- Useful for spotting recurring or worsening issues
        sum(case when not success then 1 else 0 end)
            over (
                partition by suite_name, expectation_type, coalesce(column_name, '__table__')
                order by run_time
                rows between 6 preceding and current row
            )                                                       as failures_last_7_runs,

        -- Cumulative run number for this check — helps spot new vs. long-running checks
        row_number()
            over (
                partition by suite_name, expectation_type, coalesce(column_name, '__table__')
                order by run_time
            )                                                       as check_run_number,

        -- Flag checks that failed in the most recent run (window function, not a subquery)
        not success                                                 as failed_this_run

    from validations
)

select * from enriched
order by run_time desc, suite_name, expectation_type, column_name
