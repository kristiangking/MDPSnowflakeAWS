select
    po_id,
    supplier_id,
    supplier_name,
    lead_time_days,
    location_id,
    location_name,
    city,
    status,
    created_at,
    expected_delivery_date,
    actual_delivery_date,
    total_value,
    days_to_receive,
    days_late,
    case
        when actual_delivery_date is null then 'Pending'
        when days_late > 0               then 'Late'
        else                                  'On Time'
    end as delivery_performance
from {{ ref('int_purchase_orders_enriched') }}