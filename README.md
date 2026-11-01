# ShelfPulse

A simple, end-to-end daily retail sales pipeline: **Cloudflare R2 → boto3 → Snowflake → dbt**.

POS systems in a (fictional) Kenyan supermarket chain export one CSV per store per day. ShelfPulse picks up the new files, loads them into Snowflake, and builds a trusted table of daily revenue by store and product category, with no manual loading.

## Architecture
graph LR
    %% Define Clean Structural Theme Styles
    classDef storage fill:#1E293B,stroke:#38BDF8,stroke-width:2px,color:#F8FAFC;
    classDef compute fill:#0F172A,stroke:#F43F5E,stroke-width:2px,color:#F8FAFC;
    classDef transform fill:#0F172A,stroke:#10B981,stroke-width:2px,color:#F8FAFC;
    classDef database fill:#1E293B,stroke:#0EA5E9,stroke-width:2px,color:#F8FAFC;

    %% Data Pipeline Node Elements
    R2["Cloudflare R2<br>(Landing Zone)"]:::storage
    PY["Python Script<br>(boto3 selector)"]:::compute
    STAGE["Snowflake External Stage<br>(Points to R2 Bucket)"]:::database
    RAW["Snowflake RAW<br>(Text + Lineage Columns)"]:::database
    DBT["dbt<br>(Clean, Type, Dedupe, Aggregate, Test)"]:::transform
    ANALYTICS["Snowflake ANALYTICS<br>(fct_daily_sales)"]:::database

    %% Left-to-Right Step Flows
    R2 -->|1. Scans for files| PY
    PY -->|2. Finds un-loaded items| STAGE
    STAGE -->|3. Triggers bulk load| RAW
    RAW -->|4. Processes raw objects| DBT
    DBT -->|5. Materializes metrics| ANALYTICS


| Layer | What it does |
|---|---|
| **R2 landing** | Stores raw POS CSVs under `pos_sales/` |
| **boto3 selector** | Lists R2, subtracts what is already in `RAW`, loads only the new files |
| **External stage** | Lets Snowflake read directly from R2 (S3-compatible) |
| **RAW** | Everything stored as text, plus `_source_file` and `_loaded_at` |
| **dbt** | Types, deduplicates and aggregates the data, then tests it |
| **ANALYTICS** | Final tables for analysts and BI tools |

## Project structure

```
shelfpulse/
├── README.md
├── requirements.txt
├── .env                        # your secrets (never commit this)
├── .gitignore
├── sample_data/
│   └── pos_sales/              # 5 sample CSVs (27–31 Oct 2026)
├── selector/
│   └── load_new_files.py       # boto3 selector + COPY INTO
└── dbt_shelfpulse/
    ├── dbt_project.yml
    └── models/
        ├── sources.yml
        ├── schema.yml
        ├── staging/stg_pos_sales.sql
        └── marts/fct_daily_sales.sql
```

## Prerequisites

- Python 3.9+
- A Cloudflare account with an R2 bucket
- A Snowflake account
- Git

## Python libraries

| Library | Used for |
|---|---|
| `boto3` | Listing files in R2 (S3-compatible API) |
| `snowflake-connector-python` | Running SQL and `COPY INTO` from Python |
| `python-dotenv` | Loading credentials from `.env` |
| `dbt-snowflake` | dbt Core plus the Snowflake adapter |

```bash
python -m venv .venv
source .venv/bin/activate        # Windows: .venv\Scripts\activate
pip install -r requirements.txt
```

## Sample data

`sample_data/pos_sales/` has five days of realistic Kenyan supermarket data for `STORE042` (about 80 products, prices in KES, 640 to 985 rows per day):

```
2026-10-27_store042.csv
2026-10-28_store042.csv
2026-10-29_store042.csv
2026-10-30_store042.csv
2026-10-31_store042.csv
```

Schema:

| Column | Description |
|---|---|
| `sale_id` | Unique ID per sale line |
| `store_id` | Store identifier (e.g. `STORE042`) |
| `product_id` | Product SKU |
| `category` | Product category (Staples, Dairy & Eggs, Beverages, ...) |
| `quantity` | Units sold (whole numbers) |
| `unit_price` | Price per unit in KES |
| `sold_at` | Timestamp, East Africa Time |

## Setup

### 1. Cloudflare R2

1. Create a bucket named `shelfpulse-landing`.
2. Create an **R2 API token** with Object Read access.
3. Note your **Account ID**, **Access Key ID** and **Secret Access Key**.
4. Upload the sample files under the `pos_sales/` prefix.

### 2. Snowflake

Run as a role that can create objects:

```sql
CREATE DATABASE SHELFPULSE;
CREATE SCHEMA SHELFPULSE.RAW;
CREATE SCHEMA SHELFPULSE.ANALYTICS;

CREATE WAREHOUSE SHELFPULSE_WH WAREHOUSE_SIZE = XSMALL AUTO_SUSPEND = 60;

CREATE FILE FORMAT SHELFPULSE.RAW.CSV_FMT
  TYPE = CSV
  SKIP_HEADER = 1
  FIELD_OPTIONALLY_ENCLOSED_BY = '"';

CREATE STAGE SHELFPULSE.RAW.R2_LANDING
  URL = 's3compat://shelfpulse-landing/'
  ENDPOINT = '<ACCOUNT_ID>.r2.cloudflarestorage.com'
  CREDENTIALS = (AWS_KEY_ID = '<R2_KEY>' AWS_SECRET_KEY = '<R2_SECRET>')
  FILE_FORMAT = SHELFPULSE.RAW.CSV_FMT;

CREATE TABLE SHELFPULSE.RAW.POS_SALES (
  sale_id STRING, store_id STRING, product_id STRING, category STRING,
  quantity STRING, unit_price STRING, sold_at STRING,
  _source_file STRING,
  _loaded_at TIMESTAMP_NTZ
);
```

Check the stage works:

```sql
LIST @SHELFPULSE.RAW.R2_LANDING;
```

### 3. Environment variables

Create a `.env` file in the project root:

```
R2_ACCOUNT_ID=your_cloudflare_account_id
R2_KEY=your_r2_access_key_id
R2_SECRET=your_r2_secret_access_key
SF_ACCOUNT=your_snowflake_account_identifier
SF_USER=your_snowflake_user
SF_PASSWORD=your_snowflake_password
```

Make sure `.env` is listed in `.gitignore`.

### 4. dbt profile

Add this to `~/.dbt/profiles.yml`:

```yaml
dbt_shelfpulse:
  target: dev
  outputs:
    dev:
      type: snowflake
      account: "{{ env_var('SF_ACCOUNT') }}"
      user: "{{ env_var('SF_USER') }}"
      password: "{{ env_var('SF_PASSWORD') }}"
      warehouse: SHELFPULSE_WH
      database: SHELFPULSE
      schema: ANALYTICS
      threads: 4
```

In `dbt_project.yml`, build staging models as views and marts as tables:

```yaml
models:
  dbt_shelfpulse:
    staging:
      +materialized: view
    marts:
      +materialized: table
```

## Running the pipeline

**Step 1: load new files from R2 into Snowflake RAW**

```bash
python selector/load_new_files.py
```

The selector lists every CSV under `pos_sales/`, compares it with the `_source_file` values already in `RAW.POS_SALES`, and runs `COPY INTO` for the new files only. Running it twice never double-loads a file.

**Step 2: transform with dbt**

```bash
cd dbt_shelfpulse
dbt source freshness
dbt build
```

**Run both in one go:**

```bash
python selector/load_new_files.py && cd dbt_shelfpulse && dbt build
```

## dbt models

| Model | Layer | Description |
|---|---|---|
| `stg_pos_sales` | Staging (view) | Casts types, cleans categories, removes duplicate `sale_id`s |
| `fct_daily_sales` | Marts (table) | Daily transactions, units sold and revenue by store and category |

Tests: `unique` and `not_null` on `sale_id`, `not_null` on `quantity` and `revenue`, plus a source freshness check on `_loaded_at`.

## Check the result

```sql
SELECT sales_date, SUM(revenue) AS revenue_kes
FROM SHELFPULSE.ANALYTICS.FCT_DAILY_SALES
GROUP BY 1
ORDER BY 1;
```

## Scheduling

Run it daily with cron:

```
0 5 * * * cd /path/to/shelfpulse && .venv/bin/python selector/load_new_files.py && cd dbt_shelfpulse && ../.venv/bin/dbt build
```

Or use a GitHub Actions workflow with `on: schedule: - cron: "0 5 * * *"` and store credentials as repository secrets.

## Design decisions

- **RAW is all text.** Bad data never breaks a load, and dbt handles typing with `try_to_*` functions.
- **`_source_file` is the idempotency key.** It doubles as lineage and makes reruns safe.
- **Selector instead of auto-ingest.** Simple, explicit and easy to debug. No event notifications are needed.
- **`quantity` is a whole number.** `try_to_number` truncates decimals, so weighed items are sold as packs or bunches.

## Security notes

- Never commit `.env` or credentials.
- Use a dedicated Snowflake user and role with least privilege instead of an admin login.
- Move to key-pair authentication for the Python script beyond prototyping.

## Roadmap

- [ ] Archive processed files to `processed/` in R2
- [ ] Add a `dim_stores` model
- [ ] Add row-count tests with `dbt_expectations`
- [ ] Orchestrate with Airflow or Dagster
- [ ] Connect a BI dashboard (Metabase, Power BI)

## License
