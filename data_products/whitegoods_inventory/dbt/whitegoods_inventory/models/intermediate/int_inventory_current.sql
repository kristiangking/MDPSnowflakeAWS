-- Replay the event stream to derive current stock per product/location
-- Uses the qty_after from the most recent event as the source of truth
with events as (
    select * from {{ ref('stg_inventory_events') }}
),
latest_event as (
    select
        product_id,
        location_id,
        qty_after   as qty_on_hand,
        occurred_at as last_event_at,
        row_number() over (
            partition by product_id, location_id
            order by occurred_at desc
        ) as rn
    from events
),
current_stock as (
    select product_id, location_id, qty_on_hand, last_event_at
    from latest_event
    where rn = 1
),
products as (
    select * from {{ ref('stg_products') }}
),
locations as (
    select * from {{ ref('stg_locations') }}
)
select
    cs.product_id,
    p.product_name,
    p.sku,
    p.category,
    p.brand,
    p.supplier_id,
    p.unit_cost,
    p.rrp,
    p.reorder_point,
    p.reorder_qty,
    cs.location_id,
    l.location_name,
    l.location_type,
    l.city,
    cs.qty_on_hand,
    cs.last_event_at,
    cs.qty_on_hand <= p.reorder_point   as is_below_reorder_point
from current_stock cs
left join products p   on cs.product_id  = p.product_id
left join locations l  on cs.location_id = l.location_id