select
    actual_delivery_date   as received_date,
    location_id,
    location_name,
    city,
    category,
    sum(qty_received)      as units_received,
    sum(line_total)        as value_received,
    count(distinct po_id)  as po_count,
    count(po_line_id)      as line_count
from {{ ref('int_po_lines_enriched') }}
where status = 'RECEIVED'
  and actual_delivery_date is not null
group by 1, 2, 3, 4, 5