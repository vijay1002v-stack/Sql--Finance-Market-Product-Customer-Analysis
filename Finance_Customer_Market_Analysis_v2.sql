-- ============================================================
-- Financial, Customer & Market Analysis
-- Version 2 — Bugs fixed, duplicates removed, comments improved
-- ============================================================


-- ============================================================
-- 1. INDIVIDUAL PRODUCT SALES REPORT (Croma India — FY2021)
-- ============================================================
-- Goal: Monthly product-level report to track performance.
-- Columns: Month, Product Name, Variant, Sold Qty,
--          Gross Price per item, Gross Price Total.

-- Step 1a: Identify Croma India's customer code
SELECT *
FROM dim_customer
WHERE customer LIKE '%croma%'
  AND market = 'India';
-- Result: customer_code = 90002002

-- Step 1b: Validate raw sales rows for Croma India
SELECT *
FROM fact_sales_monthly
WHERE customer_code = 90002002;


-- Step 1c: UDF — get_fiscal_year
-- Shifts calendar date forward 4 months so Sep = FY start.
-- FIX: kept as-is; referenced correctly throughout.

DELIMITER $$
CREATE DEFINER=`root`@`localhost` FUNCTION `get_fiscal_year`(
    calendar_date DATE)
RETURNS INT
DETERMINISTIC
BEGIN
    DECLARE fiscal_year INT;
    SET fiscal_year = YEAR(DATE_ADD(calendar_date, INTERVAL 4 MONTH));
    RETURN fiscal_year;
END$$
DELIMITER ;


-- Step 1d: Full product sales report for Croma India FY2021
SELECT
    fs.date,
    fs.product_code,
    dp.product,
    dp.variant,
    fg.gross_price,
    ROUND(fg.gross_price * fs.sold_quantity, 2)  AS gross_price_total,
    fs.sold_quantity
FROM fact_sales_monthly  AS fs
JOIN dim_product          AS dp ON fs.product_code = dp.product_code
JOIN fact_gross_price     AS fg ON fg.product_code = dp.product_code
                                AND get_fiscal_year(fs.date) = fg.fiscal_year
WHERE fs.customer_code = 90002002
  AND get_fiscal_year(fs.date) = 2021
ORDER BY fs.date ASC;


-- ============================================================
-- 2. GROSS MONTHLY TOTAL SALES — STORED PROCEDURE
-- ============================================================
-- Goal: Reusable proc to pull monthly gross sales for any
--       customer or comma-separated list of customers.

DELIMITER $$
CREATE DEFINER=`root`@`localhost` PROCEDURE `get_monthly_gross_sales_for_customer`(
    IN in_customer_code TEXT)
BEGIN
    SELECT
        fs.date,
        ROUND(SUM(fg.gross_price * fs.sold_quantity), 2) AS total_gross_price
    FROM fact_sales_monthly AS fs
    JOIN fact_gross_price   AS fg ON fs.product_code = fg.product_code
                                  AND get_fiscal_year(fs.date) = fg.fiscal_year
    WHERE FIND_IN_SET(fs.customer_code, in_customer_code) > 0
    GROUP BY fs.date
    ORDER BY fs.date;
END$$
DELIMITER ;


-- ============================================================
-- 3. PRE-INVOICE DEDUCTIONS, POST-INVOICE DEDUCTIONS & NET SALES
-- ============================================================

-- 3a: Pre-invoice deductions — using UDF (readable but slower)
SELECT
    fs.date,
    fs.product_code,
    dp.product,
    dp.variant,
    ROUND(fs.sold_quantity * fg.gross_price, 2)  AS gross_price_total,
    pre.pre_invoice_discount_pct
FROM fact_sales_monthly        AS fs
JOIN dim_product                AS dp  ON fs.product_code   = dp.product_code
JOIN fact_gross_price           AS fg  ON fs.product_code   = fg.product_code
                                       AND get_fiscal_year(fs.date) = fg.fiscal_year
JOIN fact_pre_invoice_deductions AS pre ON fs.customer_code = pre.customer_code
                                        AND get_fiscal_year(fs.date) = pre.fiscal_year
WHERE get_fiscal_year(fs.date) = 2021;


-- 3b: Performance-optimised version
-- Removes UDF calls; joins on the pre-computed fiscal_year column instead.
-- This allows the engine to use indexes on fiscal_year.
-- FIX: corrected broken join condition (was "fs.fiscal_year and fg.fiscal_year"
--      which evaluated as a boolean, not an equality check).
SELECT
    fs.date,
    dp.product_code,
    dp.product,
    dp.variant,
    fg.gross_price,
    ROUND(fs.sold_quantity * fg.gross_price, 2)  AS total_gross_price,
    pre.pre_invoice_discount_pct
FROM fact_sales_monthly        AS fs
JOIN dim_product                AS dp  ON fs.product_code   = dp.product_code
JOIN fact_gross_price           AS fg  ON fg.product_code   = dp.product_code
                                       AND fs.fiscal_year   = fg.fiscal_year   -- FIXED
JOIN fact_pre_invoice_deductions AS pre ON pre.customer_code = fs.customer_code
                                        AND pre.fiscal_year  = fs.fiscal_year; -- FIXED


-- 3c: Net invoice sales via CTE
WITH pre_inv AS (
    SELECT
        fs.date,
        dp.product_code,
        dp.product,
        dp.variant,
        fg.gross_price,
        ROUND(fs.sold_quantity * fg.gross_price, 2) AS total_gross_price,
        pre.pre_invoice_discount_pct
    FROM fact_sales_monthly        AS fs
    JOIN dim_product                AS dp  ON fs.product_code  = dp.product_code
    JOIN fact_gross_price           AS fg  ON fg.product_code  = dp.product_code
                                           AND fs.fiscal_year  = fg.fiscal_year
    JOIN fact_pre_invoice_deductions AS pre ON pre.customer_code = fs.customer_code
                                           AND pre.fiscal_year   = fs.fiscal_year
)
SELECT
    *,
    ROUND(gross_price - gross_price * pre_invoice_discount_pct, 2) AS net_invoice_sales
FROM pre_inv;


-- 3d: View — post-invoice deductions
-- Builds on the pre-invoice view (sales_preinv_discount) to add
-- post-invoice discounts and calculate net invoice sales.
CREATE OR REPLACE VIEW sales_postinv_discount AS
    SELECT
        sp.date,
        sp.fiscal_year,
        sp.product_code,
        sp.customer_code,
        sp.product,
        sp.variant,
        sp.gross_price,
        sp.market,
        sp.total_gross_price,
        sp.pre_invoice_discount_pct,
        ROUND(sp.total_gross_price - (sp.total_gross_price * sp.pre_invoice_discount_pct), 2)
                                                                    AS net_invoice_sales,
        (pd.discounts_pct + pd.other_deductions_pct)                AS post_invoice_discounts
    FROM sales_preinv_discount AS sp
    JOIN fact_post_invoice_deductions AS pd
        ON sp.customer_code = pd.customer_code
       AND sp.product_code  = pd.product_code
       AND sp.date           = pd.date;


-- 3e: Final net sales calculation
SELECT
    *,
    ROUND((1 - post_invoice_discounts) * net_invoice_sales, 2) AS net_sales
FROM sales_postinv_discount;


-- ============================================================
-- 4. MARKET ANALYSIS
-- ============================================================

-- 4a: Stored procedure — market badge (Gold / Silver)
-- Gold = total sold quantity > 5 million in a given fiscal year.

DELIMITER $$
CREATE DEFINER=`root`@`localhost` PROCEDURE `get_market_badge`(
    IN  in_market      VARCHAR(25),
    IN  in_fiscal_year YEAR,
    OUT out_badge      VARCHAR(10))
BEGIN
    DECLARE qty INT DEFAULT 0;

    -- Default to India if no market supplied
    IF in_market = '' THEN
        SET in_market = 'India';
    END IF;

    -- Total sold quantity for the given market + fiscal year
    SELECT SUM(fs.sold_quantity) INTO qty
    FROM fact_sales_monthly AS fs
    JOIN dim_customer        AS dc ON fs.customer_code = dc.customer_code
    WHERE get_fiscal_year(fs.date) = in_fiscal_year
      AND dc.market = in_market
    GROUP BY dc.market;

    -- Assign badge
    IF qty > 5000000 THEN
        SET out_badge = 'Gold';
    ELSE
        SET out_badge = 'Silver';
    END IF;
END$$
DELIMITER ;


-- 4b: Stored procedure — top N markets by net sales for a fiscal year

DELIMITER $$
CREATE DEFINER=`root`@`localhost` PROCEDURE `get_top_n_market`(
    IN in_fiscal_year YEAR,
    IN in_top_n       INT)
BEGIN
    SELECT
        market,
        ROUND(SUM(net_sales) / 1000000, 2) AS net_sales_mln
    FROM net_sales
    WHERE fiscal_year = in_fiscal_year      -- FIX: was "fiscal_year=fiscal_year" (always true)
    GROUP BY market
    ORDER BY net_sales_mln DESC
    LIMIT in_top_n;
END$$
DELIMITER ;


-- 4c: Top 2 markets per region by gross sales — FY2021
WITH market_data AS (
    SELECT
        c.market,
        c.region,
        ROUND(SUM(s.total_gross_price) / 1000000, 2) AS gross_sales_mln
    FROM net_sales    AS s
    JOIN dim_customer AS c ON c.customer_code = s.customer_code
    WHERE s.fiscal_year = 2021
    GROUP BY c.region, c.market
),
ranked AS (
    SELECT
        *,
        DENSE_RANK() OVER (PARTITION BY region ORDER BY gross_sales_mln DESC) AS rnk
    FROM market_data
)
SELECT *
FROM ranked
WHERE rnk <= 2;


-- ============================================================
-- 5. CUSTOMER ANALYSIS
-- ============================================================

-- 5a: Stored procedure — top N customers by net sales
--     (market + fiscal year filter)

DELIMITER $$
CREATE DEFINER=`root`@`localhost` PROCEDURE `get_top_n_customer_by_sales`(
    IN in_market       VARCHAR(25),
    IN in_fiscal_year  INT,
    IN in_top_n        INT)
BEGIN
    SELECT
        c.customer,
        ROUND(SUM(ns.net_sales) / 1000000, 2) AS net_sales_mln
    FROM net_sales    AS ns
    JOIN dim_customer AS c  ON c.customer_code = ns.customer_code
    WHERE ns.fiscal_year = in_fiscal_year
      AND c.market        = in_market
    GROUP BY c.customer
    ORDER BY net_sales_mln DESC
    LIMIT in_top_n;
END$$
DELIMITER ;


-- 5b: Region-wise customer net sales and % contribution — FY2021
WITH customer_sales AS (
    SELECT
        c.customer,
        c.region,
        ROUND(SUM(ns.net_sales) / 1000000, 2) AS net_sales_mln
    FROM net_sales    AS ns
    JOIN dim_customer AS c ON c.customer_code = ns.customer_code
    WHERE ns.fiscal_year = 2021
    GROUP BY c.region, c.customer
)
SELECT
    customer,
    region,
    net_sales_mln,
    ROUND(
        net_sales_mln * 100.0 / SUM(net_sales_mln) OVER (PARTITION BY region),
        2
    ) AS pct_share_region
FROM customer_sales
ORDER BY region, net_sales_mln DESC;


-- ============================================================
-- 6. PRODUCT ANALYSIS
-- ============================================================

-- 6a: Top 3 products per division by sold quantity — FY2021
WITH product_qty AS (
    SELECT
        p.product,
        p.division,
        SUM(s.sold_quantity) AS total_qty
    FROM net_sales   AS s
    JOIN dim_product AS p ON p.product_code = s.product_code
    WHERE s.fiscal_year = 2021
    GROUP BY p.division, p.product
),
ranked AS (
    SELECT
        *,
        DENSE_RANK() OVER (PARTITION BY division ORDER BY total_qty DESC) AS rnk
    FROM product_qty
)
SELECT *
FROM ranked
WHERE rnk <= 3;


-- 6b: Stored procedure — top N products by net sales
--     (market + fiscal year filter)
-- FIX: removed the duplicate procedure that existed in v1 under the same name.

DELIMITER $$
CREATE DEFINER=`root`@`localhost` PROCEDURE `get_top_n_product_by_sales`(
    IN in_market       VARCHAR(25),
    IN in_fiscal_year  INT,
    IN in_top_n        INT)
BEGIN
    SELECT
        p.product,
        ROUND(SUM(ns.net_sales) / 1000000, 2) AS net_sales_mln
    FROM net_sales   AS ns
    JOIN dim_product AS p ON ns.product_code = p.product_code
    WHERE ns.fiscal_year = in_fiscal_year
      AND ns.market       = in_market
    GROUP BY p.product
    ORDER BY net_sales_mln DESC
    LIMIT in_top_n;
END$$
DELIMITER ;


-- ============================================================
-- 7. GROWTH ANALYSIS — Year-over-Year by Market
-- ============================================================
-- Compares each market's net sales against the prior fiscal year
-- and calculates the YoY growth percentage.

WITH market_yearly AS (
    SELECT
        c.market,
        s.fiscal_year,
        ROUND(SUM(s.net_sales) / 1000000, 2) AS net_sales_mln
    FROM net_sales    AS s
    JOIN dim_customer AS c ON c.customer_code = s.customer_code
    GROUP BY c.market, s.fiscal_year
),
with_prev AS (
    SELECT
        *,
        LAG(net_sales_mln) OVER (PARTITION BY market ORDER BY fiscal_year) AS prev_year_sales
    FROM market_yearly
)
SELECT
    *,
    ROUND(
        (net_sales_mln - prev_year_sales) / prev_year_sales * 100,
        2
    ) AS yoy_growth_pct
FROM with_prev
ORDER BY market, fiscal_year;
