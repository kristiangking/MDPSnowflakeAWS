with source as (
    select * from {{ source('inventory', 'locations') }}
),
renamed as (
    select
        location_id,
        name   as location_name,
        type   as location_type,
        city,
        state,
        _loaded_at
    from source
)
select * from renamed