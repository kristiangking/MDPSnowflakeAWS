with source as (
    select * from {{ source('inventory', 'products') }}
),
renamed as (
    select
        product_id,
        sku,
        name          as product_name,
        category,
        brand,
        supplier_id,
        unit_cost,
        rrp,
        reorder_point,
        reorder_qty,
        weight_kg,
        _loaded_at
    from source
)
select * from renamed