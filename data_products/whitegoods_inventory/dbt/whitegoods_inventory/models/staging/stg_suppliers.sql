with source as (
    select * from {{ source('inventory', 'suppliers') }}
),
renamed as (
    select
        supplier_id,
        name           as supplier_name,
        lead_time_days,
        _loaded_at
    from source
)
select * from renamed