with source as (
    select * from {{ source('inventory', 'purchase_order_lines') }}
),
renamed as (
    select
        po_line_id,
        po_id,
        product_id,
        qty_ordered,
        qty_received,
        unit_cost,
        line_total,
        _loaded_at
    from source
)
select * from renamed