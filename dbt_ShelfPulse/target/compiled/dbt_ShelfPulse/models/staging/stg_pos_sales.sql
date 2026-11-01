with src as (
    select * from SHELFPULSE.RAW.pos_sales
),
typed as (
    select
        sale_id,
        store_id,
        product_id,
        lower(trim(category))              as category,
        try_to_number(quantity)            as quantity,
        try_to_decimal(unit_price, 10, 2)  as unit_price,
        try_to_timestamp(sold_at)          as sold_at,
        _source_file,
        _loaded_at
    from src
)
select * from typed
qualify row_number() over (partition by sale_id order by _loaded_at desc) = 1