with purchase_orders as (
    select * from {{ ref('stg_purchase_orders') }}
),
suppliers as (
    select * from {{ ref('stg_suppliers') }}
),
locations as (
    select * from {{ ref('stg_locations') }}
)
select
    po.po_id,
    po.supplier_id,
    s.supplier_name,
    s.lead_time_days,
    po.location_id,
    l.location_name,
    l.location_type,
    l.city,
    po.status,
    po.created_at,
    po.expected_delivery_date,
    po.actual_delivery_date,
    po.total_value,
    datediff('day', po.created_at::date, po.actual_delivery_date)         as days_to_receive,
    datediff('day', po.expected_delivery_date, po.actual_delivery_date)   as days_late
from purchase_orders po
left join suppliers s  on po.supplier_id = s.supplier_id
left join locations l  on po.location_id = l.location_id