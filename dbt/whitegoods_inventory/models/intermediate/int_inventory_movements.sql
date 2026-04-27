with events as (
    select * from {{ ref('stg_inventory_events') }}
),
products as (
    select * from {{ ref('stg_products') }}
),
locations as (
    select * from {{ ref('stg_locations') }}
)
select
    e.event_id,
    e.event_type,
    e.product_id,
    p.product_name,
    p.sku,
    p.category,
    e.location_id,
    l.location_name,
    l.location_type,
    e.qty_delta,
    e.qty_after,
    e.reference_id,
    e.occurred_at,
    e.occurred_at::date  as occurred_date
from events e
left join products p  on e.product_id  = p.product_id
left join locations l on e.location_id = l.location_id