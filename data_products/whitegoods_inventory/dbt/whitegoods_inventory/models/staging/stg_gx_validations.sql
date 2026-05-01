with source as (
    select * from {{ source('gx', 'validations') }}
),

renamed as (
    select
        run_id,
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
        _loaded_at
    from source
)

select * from renamed
