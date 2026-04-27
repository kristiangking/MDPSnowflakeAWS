with source as (
    select * from {{ source('inventory', 'purchase_orders') }}
),
renamed as (
    select
        po_id,
        supplier_id,
        location_id,
        status,
        created_at,
        expected_delivery_date,
        actual_delivery_date,
        total_value,
        _loaded_at
    from source
)
select * from renamed