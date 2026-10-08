-- =====================================================================
-- TraceRoot  |  Phase 2: triggers, function, stored procedures, views
-- Run AFTER schema.sql:
--     mysql -u root -p traceroot < routines.sql
-- Safe to re-run (every object is dropped first).
-- =====================================================================
USE traceroot;

DROP TRIGGER   IF EXISTS trg_inspection_fail_quarantine;
DROP TRIGGER   IF EXISTS trg_shipment_block_unsafe;
DROP VIEW      IF EXISTS v_batch_trace_summary;
DROP VIEW      IF EXISTS v_recall_impact;
DROP FUNCTION  IF EXISTS fn_batch_risk_score;
DROP PROCEDURE IF EXISTS sp_trace_recall;
DROP PROCEDURE IF EXISTS sp_split_batch;

DELIMITER $$

-- =====================================================================
-- TRIGGER (a)  AFTER INSERT ON inspections
-- A FAIL result automatically:
--   1. quarantines the batch (only if it is currently ACTIVE),
--   2. cancels every PENDING shipment of that batch,
--   3. writes audit_log rows.
-- All of it runs inside the same transaction as the inspection INSERT,
-- so either everything happens or nothing does.
-- =====================================================================
CREATE TRIGGER trg_inspection_fail_quarantine
AFTER INSERT ON inspections
FOR EACH ROW
BEGIN
    DECLARE v_old_status VARCHAR(20);
    DECLARE v_cancelled  INT DEFAULT 0;

    IF NEW.result = 'FAIL' THEN
        SELECT status INTO v_old_status
          FROM batches WHERE batch_id = NEW.batch_id;

        UPDATE batches
           SET status = 'QUARANTINED'
         WHERE batch_id = NEW.batch_id
           AND status = 'ACTIVE';

        UPDATE shipments
           SET status = 'CANCELLED'
         WHERE batch_id = NEW.batch_id
           AND status = 'PENDING';
        SET v_cancelled = ROW_COUNT();

        IF v_old_status = 'ACTIVE' THEN
            INSERT INTO audit_log (table_name, record_id, action, details, performed_by)
            VALUES ('batches', NEW.batch_id, 'QUARANTINE',
              JSON_OBJECT('inspection_id', NEW.inspection_id,
              'previous_status', v_old_status,
              'reason', 'Inspection FAILED',
              'cancelled_pending_shipments', v_cancelled),
              NEW.inspector_id);
        END IF;

        IF v_cancelled > 0 THEN
            INSERT INTO audit_log (table_name, record_id, action, details, performed_by)
            VALUES ('shipments', NEW.batch_id, 'CANCEL_SHIPMENT',
                    JSON_OBJECT('batch_id', NEW.batch_id,
                                'cancelled_count', v_cancelled,
                                'caused_by_inspection', NEW.inspection_id),
                    NEW.inspector_id);
        END IF;
    END IF;
END$$

-- =====================================================================
-- TRIGGER (b)  BEFORE INSERT ON shipments
-- Business-rule guard: unsafe stock can never be shipped, no matter
-- which application (or manual SQL) tries to do it.
-- SIGNAL SQLSTATE '45000' raises a user-defined error and aborts the INSERT.
-- Extra guard: shipment cannot exceed the batch's original quantity.
-- =====================================================================
CREATE TRIGGER trg_shipment_block_unsafe
BEFORE INSERT ON shipments
FOR EACH ROW
BEGIN
    DECLARE v_status  VARCHAR(20);
    DECLARE v_expiry  DATE;
    DECLARE v_initial DECIMAL(12,3);

    SELECT status, expiry_date, initial_quantity_kg
      INTO v_status, v_expiry, v_initial
      FROM batches WHERE batch_id = NEW.batch_id;

    IF v_status IS NULL THEN
        SIGNAL SQLSTATE '45000'
           SET MESSAGE_TEXT = 'Shipment rejected: batch does not exist';
    END IF;

    IF v_status IN ('QUARANTINED', 'RECALLED') THEN
        SIGNAL SQLSTATE '45000'
           SET MESSAGE_TEXT = 'Shipment rejected: batch is QUARANTINED or RECALLED';
    END IF;

    IF v_status = 'EXPIRED' OR v_expiry < CURDATE() THEN
        SIGNAL SQLSTATE '45000'
           SET MESSAGE_TEXT = 'Shipment rejected: batch has expired';
    END IF;

    IF NEW.quantity_kg > v_initial THEN
        SIGNAL SQLSTATE '45000'
           SET MESSAGE_TEXT = 'Shipment rejected: quantity exceeds the batch quantity';
    END IF;
END$$

-- =====================================================================
-- FUNCTION fn_batch_risk_score(batch_id)  ->  0..100  (NULL if no batch)
--   +50  the batch itself has a FAILED inspection
--   +25  any UPSTREAM ancestor batch has a FAILED inspection
--   +10  batch is currently QUARANTINED
--   +0..15  failure rate (0..1) of the origin farm(s) x 15
--   RECALLED batches are always 100.
-- Bands used by the UI:  0-24 LOW | 25-49 MEDIUM | 50-74 HIGH | 75-100 CRITICAL
-- The upstream walk is a recursive CTE with a cycle guard (path string).
-- READS SQL DATA is required so the function can be created when the
-- binary log is on (MySQL error 1418 otherwise).
-- =====================================================================
CREATE FUNCTION fn_batch_risk_score(p_batch_id INT UNSIGNED)
RETURNS TINYINT UNSIGNED
READS SQL DATA
BEGIN
    DECLARE v_status      VARCHAR(20);
    DECLARE v_direct_fail INT DEFAULT 0;
    DECLARE v_up_fail     INT DEFAULT 0;
    DECLARE v_farm_rate   DECIMAL(7,4) DEFAULT 0;
    DECLARE v_score       INT DEFAULT 0;

    SELECT status INTO v_status FROM batches WHERE batch_id = p_batch_id;
    IF v_status IS NULL THEN
        RETURN NULL;
    END IF;
    IF v_status = 'RECALLED' THEN
        RETURN 100;
    END IF;

    SELECT COUNT(*) INTO v_direct_fail
      FROM inspections
     WHERE batch_id = p_batch_id AND result = 'FAIL';

    -- failed inspections anywhere upstream
    WITH RECURSIVE upstream_cte AS (
        SELECT p_batch_id AS batch_id, 0 AS depth,
               CAST(p_batch_id AS CHAR(1000)) AS path
        UNION ALL
        SELECT l.parent_batch_id, u.depth + 1,
               CONCAT(u.path, ',', l.parent_batch_id)
          FROM upstream_cte u
          JOIN batch_lineage l ON l.child_batch_id = u.batch_id
         WHERE u.depth < 50
           AND NOT FIND_IN_SET(l.parent_batch_id, u.path)      -- cycle guard
    )
    SELECT COUNT(*) INTO v_up_fail
      FROM upstream_cte u
      JOIN inspections i ON i.batch_id = u.batch_id AND i.result = 'FAIL'
     WHERE u.depth > 0;

    -- worst historical failure rate among the farms this batch came from
    WITH RECURSIVE upstream_cte AS (
        SELECT p_batch_id AS batch_id, 0 AS depth,
               CAST(p_batch_id AS CHAR(1000)) AS path
        UNION ALL
        SELECT l.parent_batch_id, u.depth + 1,
               CONCAT(u.path, ',', l.parent_batch_id)
          FROM upstream_cte u
          JOIN batch_lineage l ON l.child_batch_id = u.batch_id
         WHERE u.depth < 50
           AND NOT FIND_IN_SET(l.parent_batch_id, u.path)
    )
    SELECT COALESCE(MAX(fr.fail_rate), 0) INTO v_farm_rate
      FROM upstream_cte u
      JOIN batches b ON b.batch_id = u.batch_id AND b.batch_type = 'HARVEST'
      JOIN (SELECT hb.farm_id,
                   SUM(i.result = 'FAIL') / COUNT(*) AS fail_rate
              FROM inspections i
              JOIN batches hb ON hb.batch_id = i.batch_id
             WHERE hb.farm_id IS NOT NULL
             GROUP BY hb.farm_id) fr
        ON fr.farm_id = b.farm_id;

    IF v_direct_fail > 0 THEN SET v_score = v_score + 50; END IF;
    IF v_up_fail     > 0 THEN SET v_score = v_score + 25; END IF;
    IF v_status = 'QUARANTINED' THEN SET v_score = v_score + 10; END IF;
    SET v_score = v_score + ROUND(v_farm_rate * 15);

    RETURN LEAST(100, v_score);
END$$

-- =====================================================================
-- PROCEDURE sp_trace_recall(batch_id)
-- Returns FOUR result sets (read them with cursor.nextset() in Python):
--   1. summary   (one row of counts + kg shipped)
--   2. trace     (every ORIGIN / UPSTREAM / DOWNSTREAM / MIXED_WITH batch)
--   3. farms     (farms that supplied the origin + upstream batches)
--   4. retailers (shops that received origin + downstream batches)
-- Concepts: recursive CTE (two directions), cycle guard via a path string
-- plus a depth cap, TEMPORARY tables to reuse the traversal for several
-- result sets. (A TEMPORARY table cannot be referenced twice inside ONE
-- statement in MySQL, which is why queries below touch it only once.)
-- MIXED_WITH = other parent batches that were merged with the affected
-- stock into the same child batch (co-mingled, listed for inspection).
-- =====================================================================
CREATE PROCEDURE sp_trace_recall(IN p_batch_id INT UNSIGNED)
BEGIN
    DECLARE v_up        INT DEFAULT 0;
    DECLARE v_down      INT DEFAULT 0;
    DECLARE v_mixed     INT DEFAULT 0;
    DECLARE v_farms     INT DEFAULT 0;
    DECLARE v_retailers INT DEFAULT 0;
    DECLARE v_kg        DECIMAL(14,3) DEFAULT 0;

    IF NOT EXISTS (SELECT 1 FROM batches WHERE batch_id = p_batch_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Batch not found';
    END IF;

    DROP TEMPORARY TABLE IF EXISTS tmp_trace;
    DROP TEMPORARY TABLE IF EXISTS tmp_mixed;

    CREATE TEMPORARY TABLE tmp_trace (
        batch_id  INT UNSIGNED NOT NULL PRIMARY KEY,
        direction ENUM('ORIGIN','UPSTREAM','DOWNSTREAM') NOT NULL,
        depth     INT NOT NULL
    );
    CREATE TEMPORARY TABLE tmp_mixed (
        batch_id     INT UNSIGNED NOT NULL,
        via_batch_id INT UNSIGNED NOT NULL,
        PRIMARY KEY (batch_id, via_batch_id)
    );

    -- ---- the recursive traversal (both directions in one statement) ----
    INSERT IGNORE INTO tmp_trace (batch_id, direction, depth)
    WITH RECURSIVE
    upstream_cte AS (
        SELECT p_batch_id AS batch_id, 0 AS depth,
               CAST(p_batch_id AS CHAR(1000)) AS path
        UNION ALL
        SELECT l.parent_batch_id, u.depth + 1,
               CONCAT(u.path, ',', l.parent_batch_id)
          FROM upstream_cte u
          JOIN batch_lineage l ON l.child_batch_id = u.batch_id
         WHERE u.depth < 50
           AND NOT FIND_IN_SET(l.parent_batch_id, u.path)       -- cycle guard
    ),
    downstream_cte AS (
        SELECT p_batch_id AS batch_id, 0 AS depth,
               CAST(p_batch_id AS CHAR(1000)) AS path
        UNION ALL
        SELECT l.child_batch_id, d.depth + 1,
               CONCAT(d.path, ',', l.child_batch_id)
          FROM downstream_cte d
          JOIN batch_lineage l ON l.parent_batch_id = d.batch_id
         WHERE d.depth < 50
           AND NOT FIND_IN_SET(l.child_batch_id, d.path)        -- cycle guard
    )
    SELECT batch_id, 'ORIGIN', 0 FROM batches WHERE batch_id = p_batch_id
    UNION ALL
    SELECT batch_id, 'UPSTREAM', MIN(depth) FROM upstream_cte
     WHERE depth > 0 GROUP BY batch_id
    UNION ALL
    SELECT batch_id, 'DOWNSTREAM', MIN(depth) FROM downstream_cte
     WHERE depth > 0 GROUP BY batch_id;

    -- ---- co-mingled batches: other parents of the origin / downstream children ----
    INSERT IGNORE INTO tmp_mixed (batch_id, via_batch_id)
    SELECT l.parent_batch_id, l.child_batch_id
      FROM tmp_trace t
      JOIN batch_lineage l ON l.child_batch_id = t.batch_id
     WHERE t.direction IN ('ORIGIN', 'DOWNSTREAM');

    DELETE FROM tmp_mixed WHERE batch_id IN (SELECT batch_id FROM tmp_trace);

    -- ---- numbers for the summary row ----
    SELECT COALESCE(SUM(direction = 'UPSTREAM'), 0),
           COALESCE(SUM(direction = 'DOWNSTREAM'), 0)
      INTO v_up, v_down
      FROM tmp_trace;

    SELECT COUNT(DISTINCT batch_id) INTO v_mixed FROM tmp_mixed;

    SELECT COUNT(DISTINCT b.farm_id) INTO v_farms
      FROM tmp_trace t
      JOIN batches b ON b.batch_id = t.batch_id AND b.batch_type = 'HARVEST'
     WHERE t.direction IN ('ORIGIN', 'UPSTREAM');

    SELECT COUNT(DISTINCT s.retailer_id), COALESCE(SUM(s.quantity_kg), 0)
      INTO v_retailers, v_kg
      FROM tmp_trace t
      JOIN shipments s ON s.batch_id = t.batch_id AND s.status <> 'CANCELLED'
     WHERE t.direction IN ('ORIGIN', 'DOWNSTREAM');

    -- ================= RESULT SET 1: summary =================
    SELECT p_batch_id          AS batch_id,
           1 + v_up + v_down   AS batches_to_hold,
           v_up                AS upstream_batches,
           v_down              AS downstream_batches,
           v_mixed             AS co_mingled_batches,
           v_farms             AS farms_affected,
           v_retailers         AS retailers_affected,
           v_kg                AS kg_in_retail_channel;

    -- ================= RESULT SET 2: trace =================
    SELECT 1 AS sort_order, CAST(t.direction AS CHAR(12)) AS direction, t.depth,
           b.batch_id, b.batch_code, pr.product_name, b.batch_type,
           b.status, b.stage, b.quantity_kg, f.farm_code,
           CAST(NULL AS CHAR(255)) AS note
      FROM tmp_trace t
      JOIN batches  b  ON b.batch_id   = t.batch_id
      JOIN products pr ON pr.product_id = b.product_id
      LEFT JOIN farms f ON f.farm_id   = b.farm_id
    UNION ALL
    SELECT 2, 'MIXED_WITH', NULL,
           b.batch_id, b.batch_code, pr.product_name, b.batch_type,
           b.status, b.stage, b.quantity_kg, f.farm_code,
           CONCAT('merged with affected stock into ', mm.via_codes)
      FROM (SELECT m.batch_id,
                   GROUP_CONCAT(vb.batch_code ORDER BY vb.batch_code SEPARATOR ', ') AS via_codes
              FROM tmp_mixed m
              JOIN batches vb ON vb.batch_id = m.via_batch_id
             GROUP BY m.batch_id) mm
      JOIN batches  b  ON b.batch_id   = mm.batch_id
      JOIN products pr ON pr.product_id = b.product_id
      LEFT JOIN farms f ON f.farm_id   = b.farm_id
    ORDER BY sort_order, depth, batch_code;

    -- ================= RESULT SET 3: affected farms =================
    SELECT f.farm_id, f.farm_code, f.farm_name, f.district, f.state,
           o.full_name AS owner_name, o.phone AS owner_phone,
           GROUP_CONCAT(b.batch_code ORDER BY b.batch_code SEPARATOR ', ') AS source_batches
      FROM tmp_trace t
      JOIN batches b ON b.batch_id = t.batch_id AND b.batch_type = 'HARVEST'
      JOIN farms   f ON f.farm_id  = b.farm_id
      JOIN users   o ON o.user_id  = f.owner_id
     WHERE t.direction IN ('ORIGIN', 'UPSTREAM')
     GROUP BY f.farm_id, f.farm_code, f.farm_name, f.district, f.state,
              o.full_name, o.phone
     ORDER BY f.farm_code;

    -- ================= RESULT SET 4: affected retailers =================
    SELECT u.user_id AS retailer_id, u.shop_name, u.full_name AS contact_name,
           u.city, u.phone, b.batch_code, s.shipment_id, s.quantity_kg,
           s.shipped_date, s.status AS shipment_status
      FROM tmp_trace t
      JOIN shipments s ON s.batch_id = t.batch_id AND s.status <> 'CANCELLED'
      JOIN batches   b ON b.batch_id = s.batch_id
      JOIN users     u ON u.user_id  = s.retailer_id
     WHERE t.direction IN ('ORIGIN', 'DOWNSTREAM')
     ORDER BY u.shop_name, s.shipped_date, b.batch_code;

    DROP TEMPORARY TABLE IF EXISTS tmp_trace;
    DROP TEMPORARY TABLE IF EXISTS tmp_mixed;
END$$

-- =====================================================================
-- PROCEDURE sp_split_batch(parent_id, user_id, children_json)   [TRANSACTION]
-- children_json example:
--   [{"qty": 40, "retailer_id": 7}, {"qty": 30, "retailer_id": 8}, {"qty": 20}]
-- (retailer_id optional: omit it to create the child without a shipment)
-- In ONE transaction:
--   lock parent row (SELECT ... FOR UPDATE) -> check quantity ->
--   insert child batches -> insert batch_lineage rows ->
--   insert shipments (trigger re-checks safety) -> reduce parent quantity.
-- Any error (including 'Insufficient quantity') triggers the EXIT HANDLER:
--   ROLLBACK, then RESIGNAL so the caller sees the original message.
-- =====================================================================
CREATE PROCEDURE sp_split_batch(IN p_parent_id INT UNSIGNED,
                                IN p_user_id   INT UNSIGNED,
                                IN p_children  JSON)
BEGIN
    DECLARE v_code     VARCHAR(30);
    DECLARE v_product  INT UNSIGNED;
    DECLARE v_unit     INT UNSIGNED;
    DECLARE v_qty      DECIMAL(12,3);
    DECLARE v_harvest  DATE;
    DECLARE v_expiry   DATE;
    DECLARE v_status   VARCHAR(20);
    DECLARE v_total    DECIMAL(12,3) DEFAULT 0;
    DECLARE v_n        INT DEFAULT 0;
    DECLARE v_i        INT DEFAULT 0;
    DECLARE v_seq      INT DEFAULT 0;
    DECLARE v_cqty     DECIMAL(12,3);
    DECLARE v_retailer INT UNSIGNED;
    DECLARE v_child_id INT UNSIGNED;
    DECLARE v_first_id INT UNSIGNED DEFAULT NULL;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF p_children IS NULL OR JSON_TYPE(p_children) <> 'ARRAY'
       OR JSON_LENGTH(p_children) < 1 THEN
        SIGNAL SQLSTATE '45000'
           SET MESSAGE_TEXT = 'children must be a non-empty JSON array';
    END IF;

    START TRANSACTION;

    SELECT batch_code, product_id, processing_unit_id, quantity_kg,
           harvest_date, expiry_date, status
      INTO v_code, v_product, v_unit, v_qty, v_harvest, v_expiry, v_status
      FROM batches
     WHERE batch_id = p_parent_id
       FOR UPDATE;                                   -- row lock: no double split

    IF v_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Parent batch not found';
    END IF;
    IF v_status <> 'ACTIVE' THEN
        SIGNAL SQLSTATE '45000'
           SET MESSAGE_TEXT = 'Only ACTIVE batches can be split';
    END IF;

    SET v_n = JSON_LENGTH(p_children);

    -- pass 1: validate and total the requested quantities
    SET v_i = 0;
    WHILE v_i < v_n DO
        SET v_cqty = CAST(JSON_UNQUOTE(
                        JSON_EXTRACT(p_children, CONCAT('$[', v_i, '].qty'))
                     ) AS DECIMAL(12,3));
        IF v_cqty IS NULL OR v_cqty <= 0 THEN
            SIGNAL SQLSTATE '45000'
               SET MESSAGE_TEXT = 'Each child needs a quantity greater than 0';
        END IF;
        SET v_total = v_total + v_cqty;
        SET v_i = v_i + 1;
    END WHILE;

    IF v_total > v_qty THEN
        SIGNAL SQLSTATE '45000'
           SET MESSAGE_TEXT = 'Insufficient quantity in parent batch - split rolled back';
    END IF;

    SELECT COUNT(*) INTO v_seq FROM batch_lineage WHERE parent_batch_id = p_parent_id;

    -- pass 2: create children, lineage rows and shipments
    SET v_i = 0;
    WHILE v_i < v_n DO
        SET v_cqty = CAST(JSON_UNQUOTE(
                        JSON_EXTRACT(p_children, CONCAT('$[', v_i, '].qty'))
                     ) AS DECIMAL(12,3));

        SET v_retailer = NULL;
        IF JSON_CONTAINS_PATH(p_children, 'one', CONCAT('$[', v_i, '].retailer_id'))
           AND JSON_TYPE(JSON_EXTRACT(p_children, CONCAT('$[', v_i, '].retailer_id'))) <> 'NULL' THEN
            SET v_retailer = CAST(JSON_UNQUOTE(
                    JSON_EXTRACT(p_children, CONCAT('$[', v_i, '].retailer_id'))
                 ) AS UNSIGNED);
            IF NOT EXISTS (SELECT 1 FROM users u JOIN roles r ON r.role_id = u.role_id
                            WHERE u.user_id = v_retailer
                              AND r.role_name = 'RETAILER' AND u.is_active = 1) THEN
                SIGNAL SQLSTATE '45000'
                   SET MESSAGE_TEXT = 'retailer_id is not an active RETAILER user';
            END IF;
        END IF;

        INSERT INTO batches (batch_code, product_id, batch_type, farm_id,
                             processing_unit_id, initial_quantity_kg, quantity_kg,
                             harvest_date, expiry_date, status, stage, created_by)
        -- a child that is shipped straight away has 0 kg left in stock
        VALUES (CONCAT(v_code, '-S', v_seq + v_i + 1), v_product, 'DERIVED', NULL,
                v_unit, v_cqty,
                CASE WHEN v_retailer IS NULL THEN v_cqty ELSE 0 END,
                v_harvest, v_expiry, 'ACTIVE',
                CASE WHEN v_retailer IS NULL THEN 'PACKED' ELSE 'SHIPPED' END,
                p_user_id);
        SET v_child_id = LAST_INSERT_ID();
        IF v_first_id IS NULL THEN SET v_first_id = v_child_id; END IF;

        INSERT INTO batch_lineage (parent_batch_id, child_batch_id, quantity_used_kg, relation_type)
        VALUES (p_parent_id, v_child_id, v_cqty, 'SPLIT');

        IF v_retailer IS NOT NULL THEN
            INSERT INTO shipments (batch_id, retailer_id, quantity_kg, shipped_date,
                                   expected_delivery, status, created_by)
            VALUES (v_child_id, v_retailer, v_cqty, CURDATE(),
                    DATE_ADD(CURDATE(), INTERVAL 2 DAY), 'PENDING', p_user_id);
        END IF;

        SET v_i = v_i + 1;
    END WHILE;

    -- reduce parent. NOTE: MySQL evaluates SET assignments left to right, so
    -- status must be assigned BEFORE quantity_kg changes.
    UPDATE batches
       SET status      = CASE WHEN quantity_kg - v_total = 0 THEN 'CONSUMED' ELSE status END,
           quantity_kg = quantity_kg - v_total
     WHERE batch_id = p_parent_id;

    IF v_unit IS NOT NULL THEN
        INSERT INTO processing_events (batch_id, unit_id, event_type, input_qty_kg,
                                       output_qty_kg, performed_by, notes)
        VALUES (p_parent_id, v_unit, 'SPLIT', v_total, v_total, p_user_id,
                CONCAT('Split into ', v_n, ' child batches'));
    END IF;

    INSERT INTO audit_log (table_name, record_id, action, details, performed_by)
    VALUES ('batches', p_parent_id, 'UPDATE',
            JSON_OBJECT('operation', 'SPLIT', 'children', v_n,
                        'total_kg_split', v_total), p_user_id);

    COMMIT;

    -- return the new children to the caller
    SELECT b.batch_id, b.batch_code, l.quantity_used_kg, s.shipment_id, s.retailer_id
      FROM batch_lineage l
      JOIN batches b ON b.batch_id = l.child_batch_id
      LEFT JOIN shipments s ON s.batch_id = b.batch_id
     WHERE l.parent_batch_id = p_parent_id AND b.batch_id >= v_first_id
     ORDER BY b.batch_id;
END$$

DELIMITER ;

-- =====================================================================
-- VIEW v_batch_trace_summary : one row per batch with its family,
-- inspection history, shipping totals and live risk score.
-- =====================================================================
CREATE VIEW v_batch_trace_summary AS
SELECT t.*,
       CASE WHEN t.risk_score >= 75 THEN 'CRITICAL'
            WHEN t.risk_score >= 50 THEN 'HIGH'
            WHEN t.risk_score >= 25 THEN 'MEDIUM'
            ELSE 'LOW' END AS risk_level
FROM (
    SELECT b.batch_id, b.batch_code, b.product_id, p.product_name, p.category,
           b.batch_type, b.status, b.stage,
           b.quantity_kg, b.initial_quantity_kg,
           b.harvest_date, b.expiry_date,
           (b.expiry_date < CURDATE())              AS is_expired,
           f.farm_id, f.farm_code, f.farm_name, f.owner_id AS farm_owner_id,
           pu.unit_name                             AS processing_unit,
           COALESCE(pc.parent_count, 0)             AS parent_count,
           pc.parent_codes,
           COALESCE(cc.child_count, 0)              AS child_count,
           cc.child_codes,
           COALESCE(ins.total_inspections, 0)       AS total_inspections,
           COALESCE(ins.failed_inspections, 0)      AS failed_inspections,
           ins.last_inspected_at,
           COALESCE(sh.shipment_count, 0)           AS shipment_count,
           COALESCE(sh.kg_shipped, 0)               AS kg_shipped,
           fn_batch_risk_score(b.batch_id)          AS risk_score
      FROM batches b
      JOIN products p              ON p.product_id = b.product_id
      LEFT JOIN farms f            ON f.farm_id    = b.farm_id
      LEFT JOIN processing_units pu ON pu.unit_id  = b.processing_unit_id
      LEFT JOIN (SELECT l.child_batch_id AS batch_id, COUNT(*) AS parent_count,
                        GROUP_CONCAT(pb.batch_code ORDER BY pb.batch_code SEPARATOR ', ') AS parent_codes
                   FROM batch_lineage l
                   JOIN batches pb ON pb.batch_id = l.parent_batch_id
                  GROUP BY l.child_batch_id) pc ON pc.batch_id = b.batch_id
      LEFT JOIN (SELECT l.parent_batch_id AS batch_id, COUNT(*) AS child_count,
                        GROUP_CONCAT(cb.batch_code ORDER BY cb.batch_code SEPARATOR ', ') AS child_codes
                   FROM batch_lineage l
                   JOIN batches cb ON cb.batch_id = l.child_batch_id
                  GROUP BY l.parent_batch_id) cc ON cc.batch_id = b.batch_id
      LEFT JOIN (SELECT batch_id, COUNT(*) AS total_inspections,
                        SUM(result = 'FAIL') AS failed_inspections,
                        MAX(inspected_at)    AS last_inspected_at
                   FROM inspections GROUP BY batch_id) ins ON ins.batch_id = b.batch_id
      LEFT JOIN (SELECT batch_id, COUNT(*) AS shipment_count,
                        SUM(quantity_kg) AS kg_shipped
                   FROM shipments WHERE status <> 'CANCELLED'
                  GROUP BY batch_id) sh ON sh.batch_id = b.batch_id
) t;

-- =====================================================================
-- VIEW v_recall_impact : one row per recall with its blast radius.
-- Uses a recursive CTE inside the view (allowed in MySQL 8) that traces
-- EVERY recall at once: the anchor row is each recall's origin batch.
-- =====================================================================
CREATE VIEW v_recall_impact AS
WITH RECURSIVE
downstream_cte AS (
    SELECT r.recall_id, r.batch_id, 0 AS depth,
           CAST(r.batch_id AS CHAR(1000)) AS path
      FROM recalls r
    UNION ALL
    SELECT d.recall_id, l.child_batch_id, d.depth + 1,
           CONCAT(d.path, ',', l.child_batch_id)
      FROM downstream_cte d
      JOIN batch_lineage l ON l.parent_batch_id = d.batch_id
     WHERE d.depth < 50
       AND NOT FIND_IN_SET(l.child_batch_id, d.path)
),
upstream_cte AS (
    SELECT r.recall_id, r.batch_id, 0 AS depth,
           CAST(r.batch_id AS CHAR(1000)) AS path
      FROM recalls r
    UNION ALL
    SELECT u.recall_id, l.parent_batch_id, u.depth + 1,
           CONCAT(u.path, ',', l.parent_batch_id)
      FROM upstream_cte u
      JOIN batch_lineage l ON l.child_batch_id = u.batch_id
     WHERE u.depth < 50
       AND NOT FIND_IN_SET(l.parent_batch_id, u.path)
),
dn_stats AS (
    SELECT recall_id,
           COUNT(DISTINCT CASE WHEN depth > 0 THEN batch_id END) AS downstream_batches
      FROM downstream_cte GROUP BY recall_id
),
up_stats AS (
    SELECT u.recall_id,
           COUNT(DISTINCT CASE WHEN u.depth > 0 THEN u.batch_id END) AS upstream_batches,
           COUNT(DISTINCT b.farm_id) AS farms_affected
      FROM upstream_cte u
      JOIN batches b ON b.batch_id = u.batch_id
     GROUP BY u.recall_id
),
ship_stats AS (
    SELECT dd.recall_id,
           COUNT(DISTINCT s.retailer_id) AS retailers_affected,
           COUNT(s.shipment_id)          AS shipments_affected,
           COALESCE(SUM(s.quantity_kg), 0) AS kg_shipped
      FROM (SELECT DISTINCT recall_id, batch_id FROM downstream_cte) dd
      JOIN shipments s ON s.batch_id = dd.batch_id AND s.status <> 'CANCELLED'
     GROUP BY dd.recall_id
)
SELECT r.recall_id, r.recall_code, r.severity, r.status AS recall_status,
       r.reason, r.issued_at, r.closed_at,
       b.batch_id AS origin_batch_id, b.batch_code AS origin_batch_code,
       pr.product_name,
       u.full_name AS issued_by_name,
       COALESCE(dn.downstream_batches, 0) AS downstream_batches,
       COALESCE(up.upstream_batches, 0)   AS upstream_batches,
       COALESCE(up.farms_affected, 0)     AS farms_affected,
       COALESCE(sh.retailers_affected, 0) AS retailers_affected,
       COALESCE(sh.shipments_affected, 0) AS shipments_affected,
       COALESCE(sh.kg_shipped, 0)         AS kg_shipped
  FROM recalls r
  JOIN batches  b  ON b.batch_id    = r.batch_id
  JOIN products pr ON pr.product_id = b.product_id
  JOIN users    u  ON u.user_id     = r.issued_by
  LEFT JOIN dn_stats   dn ON dn.recall_id = r.recall_id
  LEFT JOIN up_stats   up ON up.recall_id = r.recall_id
  LEFT JOIN ship_stats sh ON sh.recall_id = r.recall_id;

-- ---------------------------------------------------------------------
-- Check:  SHOW TRIGGERS;  SHOW FUNCTION STATUS WHERE Db='traceroot';
--         SHOW PROCEDURE STATUS WHERE Db='traceroot';  SHOW FULL TABLES WHERE Table_type='VIEW';
-- ---------------------------------------------------------------------
