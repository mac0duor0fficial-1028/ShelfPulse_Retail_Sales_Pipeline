
  create or replace   view SHELFPULSE.ANALYTICS.fct_daily_sales
  
  
  
  
  as (
    select
    date_trunc('day', sold_at)       as sales_date,
    store_id,
    category,
    count(distinct sale_id)          as transactions,
    sum(quantity)                    as units_sold,
    sum(quantity * unit_price)       as revenue
from SHELFPULSE.ANALYTICS.stg_pos_sales
where sold_at is not null
group by 1, 2, 3
  );

