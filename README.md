# 📊 Finance, Customer & Market Analysis — SQL Project

A comprehensive SQL-based analytics project built on a retail sales database, covering financial reporting, customer segmentation, market performance, and year-over-year growth analysis.

---

## 🗂️ Table of Contents

- [Project Overview](#project-overview)
- [Database Schema](#database-schema)
- [Modules](#modules)
  - [1. Financial Analysis](#1-financial-analysis)
  - [2. Market Analysis](#2-market-analysis)
  - [3. Customer Analysis](#3-customer-analysis)
  - [4. Product Analysis](#4-product-analysis)
  - [5. Growth Analysis](#5-growth-analysis)
- [Key SQL Concepts Used](#key-sql-concepts-used)
- [Performance Optimizations](#performance-optimizations)

---

## Project Overview

This project implements a layered SQL analytics pipeline for a retail business (modeled on Croma India). It progressively computes:

- **Gross Sales** → Pre-Invoice Deductions → Net Invoice Sales → Post-Invoice Deductions → **Net Sales**

Reports are generated at the product, customer, market, and regional levels, with stored procedures and views for reusability.

---

## Database Schema

| Table | Description |
|---|---|
| `dim_customer` | Customer master — customer, customer_code ,platform ,channel, market, region |
| `dim_product` | Product master — product_code, division, segment, category, product, variant|
| `fact_sales_monthly` | Monthly sold quantity per customer & product |
| `fact_gross_price` | Gross price per product per fiscal year |
| `fact_pre_invoice_deductions` | Pre-invoice discount % per customer per fiscal year |
| `fact_post_invoice_deductions` | Post-invoice discount % and other deductions per transaction |

**Views:**

| View | Description |
|---|---|
| `sales_preinv_discount` | Gross price with pre-invoice discount applied |
| `sales_postinv_discount` | Extends above with post-invoice deductions and net invoice sales |
| `net_sales` | Final net sales figure after all deductions |

---

## Modules

### 1. Financial Analysis

**Goal:** Build a product-level monthly sales report for Croma India (FY2021).

**Steps:**

- Identified Croma India's `customer_code` from `dim_customer`.
- Created a **User-Defined Function** `get_fiscal_year(calendar_date)` to map calendar dates to fiscal years (September–August cycle).
- Joined `fact_sales_monthly`, `dim_product`, and `fact_gross_price` to produce a report with:
  - Month, Product Name, Variant, Sold Quantity, Gross Price per Item, Gross Price Total.
- Created a **Stored Procedure** `get_monthly_gross_sales_for_customer` to generate a monthly gross sales summary for any customer(s) passed as input.

---

### 2. Market Analysis

**Goal:** Rank markets and assign performance badges based on sales volume.

**Components:**

- **`get_market_badge` (Stored Procedure):** Evaluates total sold quantity for a given market and fiscal year. Markets exceeding 5 million units are labelled **Gold**; others are labelled **Silver**.
- **`get_top_n_market` (Stored Procedure):** Returns the top N markets by net sales (in millions) for a given fiscal year.
- **Top 2 Markets per Region (Ad-hoc Query):** Uses `DENSE_RANK()` partitioned by region to identify the top 2 markets in each region by gross sales for FY2021.

---

### 3. Customer Analysis

**Goal:** Measure customer contribution to net sales across regions.

**Components:**

- **`get_top_n_customer_by_sales` (Stored Procedure):** Returns the top N customers by net sales for a specified market and fiscal year.
- **Region-wise Customer Contribution (Ad-hoc Query):** Computes each customer's net sales and their percentage share within their region using a `SUM() OVER (PARTITION BY region)` window function.

---

### 4. Product Analysis

**Goal:** Identify top-performing products by division and net sales.

**Components:**

- **Top 3 Products per Division (Ad-hoc Query):** Uses `DENSE_RANK()` partitioned by division, ordered by total sold quantity, to surface the top 3 products in each division for FY2021.
- **`get_top_n_product_by_sales` (Stored Procedure):** Returns top N products by net sales for a given market and fiscal year (reusable across analyses).

---

### 5. Growth Analysis

**Goal:** Track year-over-year market performance.

**Query:** Computes net sales per market per fiscal year, then uses the `LAG()` window function (partitioned by market, ordered by fiscal year) to retrieve the prior year's sales and calculate **YoY Growth %**:

```
YoY Growth % = (Current Year Sales − Previous Year Sales) / Previous Year Sales × 100
```

---

## Key SQL Concepts Used

| Concept | Usage |
|---|---|
| **User-Defined Function** | `get_fiscal_year()` — maps calendar date to fiscal year |
| **Stored Procedures** | Monthly sales report, market badge, top N market/product/customer |
| **CTEs (`WITH` clause)** | Multi-step deduction calculations, ranking queries |
| **Window Functions** | `DENSE_RANK()`, `LAG()`, `OVER()` ,`Row_Number()`for rankings, YoY, and share |
| **SQL Views** | `sales_preinv_discount`, `sales_postinv_discount`, `net_sales` |
| **Multi-table JOINs** | Combining sales, product, price, customer, and deduction tables |
| **Aggregations** | `SUM()`, `ROUND()`, `GROUP BY` for revenue totals |
| **`FIND_IN_SET()`** | Filtering on comma-separated customer code lists in stored procedures |

---


### Running the Scripts

**1. Create the fiscal year function:**
```sql
-- Run the get_fiscal_year() UDF first — it is a dependency for most queries
CREATE FUNCTION get_fiscal_year(calendar_date DATE) RETURNS INT ...
```

**2. Build views in order:**
```sql
-- Views must be created in dependency order
-- 1. sales_preinv_discount
-- 2. sales_postinv_discount  (depends on sales_preinv_discount)
-- 3. net_sales               (depends on sales_postinv_discount)
```

**3. Create stored procedures:**
```sql
CALL get_monthly_gross_sales_for_customer('90002002');
CALL get_market_badge('India', 2021, @badge);  SELECT @badge;
CALL get_top_n_market(2021, 5);
CALL get_top_n_product_by_sales('India', 2021, 3);
```

---

## Performance Optimizations

| Issue | Optimization Applied |
|---|---|
| `get_fiscal_year()` UDF called row-by-row on large tables | Replaced with a pre-computed `fiscal_year` column in `fact_sales_monthly` and joined directly |
| Repeated deduction calculations | Encapsulated in SQL Views (`sales_preinv_discount`, `sales_postinv_discount`) for reuse |
| Ad-hoc customer filtering | Used `FIND_IN_SET()` in stored procedures to support multi-customer input |

---
