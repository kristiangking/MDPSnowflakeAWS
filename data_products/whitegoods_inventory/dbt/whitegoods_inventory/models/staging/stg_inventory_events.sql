with source as (
    select * from {{ source('inventory', 'inventory_events') }}
),
renamed as (
    select
        event_id,
        event_type,
        product_id,
        location_id,
        qty_delta,
        qty_after,
        reference_id,
        occurred_at,
        _loaded_at
    from source
)
select * from renamed