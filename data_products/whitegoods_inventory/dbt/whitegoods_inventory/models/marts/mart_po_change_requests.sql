with change_requests as (

    select * from {{ ref('stg_po_change_requests') }}

),

purchase_orders as (

    select * from {{ ref('stg_purchase_orders') }}

),

suppliers as (

    select * from {{ ref('stg_suppliers') }}

),

enriched as (

    select
        cr.event_id,
        cr.po_id,
        cr.supplier_id,
        s.supplier_name,
        cr.change_type,
        cr.line_id,
        cr.original_value,
        cr.requested_value,
        cr.reason,
        cr.requested_by,
        cr.requested_at,
        cr.received_at,

        -- PO context
        po.status                                       as po_status,
        po.order_date                                   as po_order_date,
        po.expected_delivery_date                       as po_expected_delivery_date,
        po.total_value                                  as po_total_value,

        -- Derived flags
        case
            when po.status = 'CANCELLED'  then true
            else false
        end                                             as po_already_cancelled,

        datediff('day', cr.received_at, current_timestamp())  as days_since_request,

        cr._loaded_at

    from change_requests cr
    left join purchase_orders po on cr.po_id = po.po_id
    left join suppliers       s  on cr.supplier_id = s.supplier_id

)

select * from enriched
