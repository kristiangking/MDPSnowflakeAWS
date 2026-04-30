select
    occurred_date,
    location_id,
    location_name,
    category,
    event_type,
    sum(qty_delta)          as total_qty_delta,
    sum(abs(qty_delta))     as total_units_moved,
    count(event_id)         as event_count
from {{ ref('int_inventory_movements') }}
group by 1, 2, 3, 4, 5