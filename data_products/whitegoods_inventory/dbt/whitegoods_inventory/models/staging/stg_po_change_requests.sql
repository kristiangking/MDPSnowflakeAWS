with source as (

    select * from {{ source('whitegoods_raw_api_events', 'po_change_requests') }}

),

renamed as (

    select
        event_id,
        po_id,
        supplier_id,
        upper(change_type)      as change_type,
        line_id,
        original_value,
        requested_value,
        reason,
        requested_by,
        requested_at,
        received_at,
        _loaded_at

    from source

)

select * from renamed
