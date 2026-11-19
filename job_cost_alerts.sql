-- Job cost alert queries for Databricks SQL Alerts.
-- Save each query on its own in the SQL editor, then create an alert on it.
-- Each returns one row; the alert condition is noted above the query.
-- Thresholds are examples: change them to the client's numbers.


-- 1. DAILY JOB SPEND SPIKE
-- Alert when: spike_ratio > 1.5  (and yesterday_cost > 100, to ignore tiny bases)
-- Schedule: daily, 08:00
WITH daily AS (
  SELECT u.usage_date, SUM(u.usage_quantity * lp.pricing.default) AS cost
  FROM system.billing.usage u
  INNER JOIN system.billing.list_prices lp
    ON u.cloud = lp.cloud AND u.sku_name = lp.sku_name
   AND u.usage_start_time >= lp.price_start_time
   AND (u.usage_end_time <= lp.price_end_time OR lp.price_end_time IS NULL)
  WHERE u.usage_date BETWEEN date_sub(current_date(), 8) AND date_sub(current_date(), 1)
    AND (u.billing_origin_product = 'JOBS'
         OR (u.billing_origin_product = 'SQL' AND u.usage_metadata.job_id IS NOT NULL))
  GROUP BY u.usage_date
)
SELECT
  MAX(CASE WHEN usage_date = date_sub(current_date(), 1) THEN cost END) AS yesterday_cost,
  AVG(CASE WHEN usage_date < date_sub(current_date(), 1) THEN cost END) AS avg_prior_7_days,
  MAX(CASE WHEN usage_date = date_sub(current_date(), 1) THEN cost END)
    / NULLIF(AVG(CASE WHEN usage_date < date_sub(current_date(), 1) THEN cost END), 0) AS spike_ratio
FROM daily;


-- 2. SPEND ON FAILED RUNS (YESTERDAY)
-- Alert when: failed_run_cost > 50
-- Schedule: daily, 08:00
WITH runs AS (
  SELECT workspace_id, job_id, run_id, MAX(result_state) AS result_state
  FROM system.lakeflow.job_run_timeline
  WHERE period_start_time >= date_sub(current_date(), 8)
  GROUP BY workspace_id, job_id, run_id
)
SELECT
  COALESCE(SUM(u.usage_quantity * lp.pricing.default), 0) AS failed_run_cost,
  COUNT(DISTINCT r.run_id) AS failed_runs
FROM system.billing.usage u
INNER JOIN system.billing.list_prices lp
  ON u.cloud = lp.cloud AND u.sku_name = lp.sku_name
 AND u.usage_start_time >= lp.price_start_time
 AND (u.usage_end_time <= lp.price_end_time OR lp.price_end_time IS NULL)
INNER JOIN runs r
  ON u.workspace_id = r.workspace_id
 AND u.usage_metadata.job_id = r.job_id
 AND u.usage_metadata.job_run_id = r.run_id
WHERE u.usage_date = date_sub(current_date(), 1)
  AND r.result_state IN ('FAILED', 'ERROR', 'TIMED_OUT');


-- 3. ANOMALOUS RUNS (YESTERDAY)
-- Alert when: anomalous_runs > 0
-- Schedule: daily, 08:00. The runs themselves are listed (flagged "Anomalous")
-- in the dashboard's "Most Expensive Job Runs" table.
WITH run_cost AS (
  SELECT
    u.workspace_id,
    u.usage_metadata.job_id AS job_id,
    u.usage_metadata.job_run_id AS run_id,
    MAX(u.usage_date) AS last_usage_date,
    SUM(u.usage_quantity * lp.pricing.default) AS cost
  FROM system.billing.usage u
  INNER JOIN system.billing.list_prices lp
    ON u.cloud = lp.cloud AND u.sku_name = lp.sku_name
   AND u.usage_start_time >= lp.price_start_time
   AND (u.usage_end_time <= lp.price_end_time OR lp.price_end_time IS NULL)
  WHERE u.usage_date >= date_sub(current_date(), 30)
    AND u.usage_metadata.job_run_id IS NOT NULL
    AND (u.billing_origin_product = 'JOBS'
         OR (u.billing_origin_product = 'SQL' AND u.usage_metadata.job_id IS NOT NULL))
  GROUP BY ALL
),
scored AS (
  SELECT *,
    percentile_approx(cost, 0.5) OVER (PARTITION BY workspace_id, job_id) AS job_median,
    COUNT(*) OVER (PARTITION BY workspace_id, job_id) AS job_runs
  FROM run_cost
)
SELECT COUNT(*) AS anomalous_runs, COALESCE(SUM(cost), 0) AS anomalous_run_cost
FROM scored
WHERE last_usage_date = date_sub(current_date(), 1)
  AND job_runs >= 5
  AND cost > 2 * job_median;


-- 4. MONTH-TO-DATE JOB SPEND VS BUDGET
-- Alert when: pct_of_budget > 0.8   (set monthly_budget below)
-- Schedule: daily, 08:00
SELECT
  SUM(u.usage_quantity * lp.pricing.default) AS mtd_job_cost,
  10000 AS monthly_budget,
  SUM(u.usage_quantity * lp.pricing.default) / 10000 AS pct_of_budget
FROM system.billing.usage u
INNER JOIN system.billing.list_prices lp
  ON u.cloud = lp.cloud AND u.sku_name = lp.sku_name
 AND u.usage_start_time >= lp.price_start_time
 AND (u.usage_end_time <= lp.price_end_time OR lp.price_end_time IS NULL)
WHERE u.usage_date >= trunc(current_date(), 'MM')
  AND (u.billing_origin_product = 'JOBS'
       OR (u.billing_origin_product = 'SQL' AND u.usage_metadata.job_id IS NOT NULL));
