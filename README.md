# ShelfPulse_Retail_Sales_Pipeline
ShelfPulse is a daily retail sales pipeline. POS CSVs land in Cloudflare R2, a boto3 selector finds new files and loads them into Snowflake via an external stage, and dbt transforms the raw data into analytics tables for revenue by store and category.
