with po_lines as (
    select * from {{ ref('stg_purchase_order_lines') }}
),
products as (
    select * from {{ ref('stg_products') }}
),
purchase_orders as (
    select * from {{ ref('stg_purchase_orders') }}
),
locations as (
    select * from {{ ref('stg_locations') }}
)
select
    pol.po_line_id,
    pol.po_id,
    po.supplier_id,
    po.location_id,
    l.location_name,
    l.city,
    po.status,
    po.created_at          as po_created_at,
    po.actual_delivery_date,
    pol.product_id,
    p.product_name,
    p.sku,
    p.category,
    p.brand,
    pol.qty_ordered,
    pol.qty_received,
    pol.qty_ordered - pol.qty_received  as qty_outstanding,
    pol.unit_cost,
    pol.line_total
from po_lines pol
left join products p       on pol.product_id = p.product_id
left join purchase_orders po on pol.po_id    = po.po_id
left join locations l      on po.location_id = l.location_id