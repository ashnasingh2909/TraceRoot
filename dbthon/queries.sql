-- =====================================================================
-- TraceRoot | Phase 2: demo queries (JOIN, aggregate + HAVING, recursive)
-- Run after Phase 3 seed data is loaded. All are read-only.
-- =====================================================================
USE traceroot;

-- ---------------------------------------------------------------------
-- Q1. JOIN: batch -> product -> farm -> owner, with inspection counts
--     (INNER JOINs for mandatory links, LEFT JOINs for optional ones)
-- ---------------------------------------------------------------------
SELECT b.batch_code, p.product_name, f.farm_name, o.full_name AS farmer,
       b.status, b.quantity_kg,
       COUNT(i.inspection_id)  AS inspections,
       SUM(i.result = 'FAIL')  AS failures
  FROM batches b
  JOIN products p      ON p.product_id = b.product_id
  LEFT JOIN farms f    ON f.farm_id    = b.farm_id
  LEFT JOIN users o    ON o.user_id    = f.owner_id
  LEFT JOIN inspections i ON i.batch_id = b.batch_id
 GROUP BY b.batch_id, b.batch_code, p.product_name, f.farm_name,
          o.full_name, b.status, b.quantity_kg
 ORDER BY b.batch_code;

-- ---------------------------------------------------------------------
-- Q2. AGGREGATE + HAVING: farm failure rate
--     WHERE filters rows BEFORE grouping; HAVING filters groups AFTER.
-- ---------------------------------------------------------------------
SELECT f.farm_code, f.farm_name, f.district,
       COUNT(i.inspection_id)                              AS total_inspections,
       SUM(i.result = 'FAIL')                              AS failed,
       ROUND(100 * SUM(i.result = 'FAIL') / COUNT(*), 2)   AS failure_pct
  FROM farms f
  JOIN batches b     ON b.farm_id  = f.farm_id
  JOIN inspections i ON i.batch_id = b.batch_id
 GROUP BY f.farm_id, f.farm_code, f.farm_name, f.district
HAVING COUNT(*) >= 2 AND failure_pct >= 20
 ORDER BY failure_pct DESC;

-- ---------------------------------------------------------------------
-- Q3. AGGREGATE: kg shipped per retailer in the last 30 days
-- ---------------------------------------------------------------------
SELECT u.shop_name, u.city,
       COUNT(s.shipment_id)  AS shipments,
       SUM(s.quantity_kg)    AS total_kg
  FROM shipments s
  JOIN users u ON u.user_id = s.retailer_id
 WHERE s.shipped_date >= CURDATE() - INTERVAL 30 DAY
   AND s.status <> 'CANCELLED'
 GROUP BY u.user_id, u.shop_name, u.city
 ORDER BY total_kg DESC;

-- ---------------------------------------------------------------------
-- Q4. RECURSIVE CTE: full lineage forest, indented
--     Roots = batches that have no parent. Each recursion step walks one
--     generation down through batch_lineage.
-- ---------------------------------------------------------------------
WITH RECURSIVE tree AS (
    SELECT b.batch_id, b.batch_code, 0 AS depth,
           CAST(b.batch_code AS CHAR(1000)) AS path
      FROM batches b
     WHERE NOT EXISTS (SELECT 1 FROM batch_lineage l WHERE l.child_batch_id = b.batch_id)
    UNION ALL
    SELECT c.batch_id, c.batch_code, t.depth + 1,
           CONCAT(t.path, ' > ', c.batch_code)
      FROM tree t
      JOIN batch_lineage l ON l.parent_batch_id = t.batch_id
      JOIN batches c       ON c.batch_id        = l.child_batch_id
     WHERE t.depth < 50
)
SELECT CONCAT(REPEAT('    ', depth), batch_code) AS lineage_tree, depth, path
  FROM tree
 ORDER BY path;

-- ---------------------------------------------------------------------
-- Q5. SEARCH / FILTER template (used by the Flask search page).
--     The app builds the WHERE clause dynamically but ALWAYS passes values
--     as bound parameters (never string concatenation) -> no SQL injection.
-- ---------------------------------------------------------------------
-- SELECT b.batch_id, b.batch_code, p.product_name, f.farm_name, b.status, b.harvest_date
--   FROM batches b
--   JOIN products p   ON p.product_id = b.product_id
--   LEFT JOIN farms f ON f.farm_id    = b.farm_id
--  WHERE b.batch_code LIKE CONCAT('%', :code, '%')      -- by ID / code
--    AND b.product_id = :product_id                     -- by product
--    AND b.farm_id    = :farm_id                        -- by farm
--    AND b.status     = :status                         -- by status
--    AND b.harvest_date BETWEEN :date_from AND :date_to -- by date range
--  ORDER BY b.harvest_date DESC;

-- ---------------------------------------------------------------------
-- Q6. Using the Phase 2 objects
-- ---------------------------------------------------------------------
-- SELECT * FROM v_batch_trace_summary ORDER BY risk_score DESC;
-- SELECT * FROM v_recall_impact;
-- CALL sp_trace_recall(1);
-- SELECT fn_batch_risk_score(1);
