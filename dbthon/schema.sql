-- =====================================================================
-- TraceRoot: Farm-to-Shelf Food Batch Tracking and Recall Management
-- Phase 1: schema.sql  (MySQL 8.0.16+ required for enforced CHECKs)
-- Run:  mysql -u root -p < schema.sql
-- =====================================================================

CREATE DATABASE IF NOT EXISTS traceroot
    CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE traceroot;

-- Safe to re-run: drop children before parents
SET FOREIGN_KEY_CHECKS = 0;
DROP TABLE IF EXISTS audit_log, recalls, shipments, inspection_parameters,
                     inspections, processing_events, batch_lineage, batches,
                     processing_units, products, farms, users, roles;
SET FOREIGN_KEY_CHECKS = 1;

-- ---------------------------------------------------------------------
-- 1. roles  (RBAC lookup)
-- ---------------------------------------------------------------------
CREATE TABLE roles (
    role_id      TINYINT UNSIGNED NOT NULL AUTO_INCREMENT,
    role_name    ENUM('ADMIN','FARMER','PROCESSOR','INSPECTOR',
                      'RETAILER','FOOD_SAFETY_OFFICER') NOT NULL,
    description  VARCHAR(255) NULL,
    PRIMARY KEY (role_id),
    UNIQUE KEY uq_roles_name (role_name)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 2. users  (retailers are users with the RETAILER role)
-- ---------------------------------------------------------------------
CREATE TABLE users (
    user_id        INT UNSIGNED NOT NULL AUTO_INCREMENT,
    username       VARCHAR(50)  NOT NULL,
    email          VARCHAR(120) NOT NULL,
    password_hash  VARCHAR(255) NOT NULL,              -- bcrypt hash, never plaintext
    full_name      VARCHAR(100) NOT NULL,
    phone          VARCHAR(20)  NULL,
    role_id        TINYINT UNSIGNED NOT NULL,
    shop_name      VARCHAR(120) NULL,                  -- used when role = RETAILER
    city           VARCHAR(80)  NULL,
    is_active      TINYINT(1)   NOT NULL DEFAULT 1,
    created_at     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (user_id),
    UNIQUE KEY uq_users_username (username),
    UNIQUE KEY uq_users_email (email),
    INDEX idx_users_role (role_id),
    CONSTRAINT fk_users_role FOREIGN KEY (role_id) REFERENCES roles (role_id),
    CONSTRAINT ck_users_username_len CHECK (CHAR_LENGTH(username) >= 3),
    CONSTRAINT ck_users_email_fmt    CHECK (email LIKE '%_@_%._%'),
    CONSTRAINT ck_users_active       CHECK (is_active IN (0,1))
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 3. farms
-- ---------------------------------------------------------------------
CREATE TABLE farms (
    farm_id            INT UNSIGNED NOT NULL AUTO_INCREMENT,
    farm_code          VARCHAR(20)  NOT NULL,
    farm_name          VARCHAR(120) NOT NULL,
    owner_id           INT UNSIGNED NOT NULL,          -- user with FARMER role
    village            VARCHAR(80)  NULL,
    district           VARCHAR(80)  NOT NULL,
    state              VARCHAR(80)  NOT NULL,
    area_acres         DECIMAL(8,2) NOT NULL,
    organic_certified  TINYINT(1)   NOT NULL DEFAULT 0,
    status             ENUM('ACTIVE','QUARANTINED') NOT NULL DEFAULT 'ACTIVE',
    created_at         DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (farm_id),
    UNIQUE KEY uq_farms_code (farm_code),
    INDEX idx_farms_owner (owner_id),
    CONSTRAINT fk_farms_owner FOREIGN KEY (owner_id) REFERENCES users (user_id),
    CONSTRAINT ck_farms_area  CHECK (area_acres > 0)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 4. products
-- ---------------------------------------------------------------------
CREATE TABLE products (
    product_id       INT UNSIGNED NOT NULL AUTO_INCREMENT,
    product_name     VARCHAR(100) NOT NULL,
    category         ENUM('SPICE','LEAFY_VEGETABLE','OTHER') NOT NULL,
    shelf_life_days  SMALLINT UNSIGNED NOT NULL,
    PRIMARY KEY (product_id),
    UNIQUE KEY uq_products_name (product_name),
    CONSTRAINT ck_products_shelf CHECK (shelf_life_days > 0)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 5. processing_units
-- ---------------------------------------------------------------------
CREATE TABLE processing_units (
    unit_id           INT UNSIGNED NOT NULL AUTO_INCREMENT,
    unit_code         VARCHAR(20)  NOT NULL,
    unit_name         VARCHAR(120) NOT NULL,
    location          VARCHAR(150) NOT NULL,
    fssai_license_no  VARCHAR(30)  NOT NULL,
    manager_id        INT UNSIGNED NULL,               -- user with PROCESSOR role
    PRIMARY KEY (unit_id),
    UNIQUE KEY uq_units_code (unit_code),
    UNIQUE KEY uq_units_license (fssai_license_no),
    INDEX idx_units_manager (manager_id),
    CONSTRAINT fk_units_manager FOREIGN KEY (manager_id) REFERENCES users (user_id)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 6. batches
--    HARVEST batch : comes from exactly one farm (farm_id NOT NULL)
--    DERIVED batch : produced by split/merge/process; farm is found
--                    through batch_lineage (farm_id NULL) -> keeps 3NF,
--                    because a merged batch can have MANY farms.
-- ---------------------------------------------------------------------
CREATE TABLE batches (
    batch_id             INT UNSIGNED NOT NULL AUTO_INCREMENT,
    batch_code           VARCHAR(30)  NOT NULL,
    product_id           INT UNSIGNED NOT NULL,
    batch_type           ENUM('HARVEST','DERIVED') NOT NULL DEFAULT 'HARVEST',
    farm_id              INT UNSIGNED NULL,
    processing_unit_id   INT UNSIGNED NULL,
    initial_quantity_kg  DECIMAL(12,3) NOT NULL,
    quantity_kg          DECIMAL(12,3) NOT NULL,        -- remaining quantity
    harvest_date         DATE NOT NULL,
    expiry_date          DATE NOT NULL,
    status               ENUM('ACTIVE','QUARANTINED','RECALLED','CONSUMED','EXPIRED')
                             NOT NULL DEFAULT 'ACTIVE',
    stage                ENUM('HARVESTED','PROCESSING','PACKED','SHIPPED')
                             NOT NULL DEFAULT 'HARVESTED',
    created_by           INT UNSIGNED NOT NULL,
    created_at           DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at           DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
                             ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (batch_id),
    UNIQUE KEY uq_batches_code (batch_code),
    INDEX idx_batches_farm (farm_id),                   -- REQUIRED INDEX
    INDEX idx_batches_product (product_id),
    INDEX idx_batches_status (status),
    INDEX idx_batches_harvest_date (harvest_date),
    INDEX idx_batches_unit (processing_unit_id),
    INDEX idx_batches_creator (created_by),
    CONSTRAINT fk_batches_product FOREIGN KEY (product_id) REFERENCES products (product_id),
    CONSTRAINT fk_batches_farm    FOREIGN KEY (farm_id) REFERENCES farms (farm_id),
    CONSTRAINT fk_batches_unit    FOREIGN KEY (processing_unit_id) REFERENCES processing_units (unit_id),
    CONSTRAINT fk_batches_creator FOREIGN KEY (created_by) REFERENCES users (user_id),
    CONSTRAINT ck_batches_initial_qty CHECK (initial_quantity_kg > 0),
    CONSTRAINT ck_batches_qty         CHECK (quantity_kg >= 0 AND quantity_kg <= initial_quantity_kg),
    CONSTRAINT ck_batches_dates       CHECK (expiry_date > harvest_date),
    CONSTRAINT ck_batches_origin      CHECK (
        (batch_type = 'HARVEST' AND farm_id IS NOT NULL) OR
        (batch_type = 'DERIVED' AND farm_id IS NULL)
    )
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 7. batch_lineage  (the family tree: a self-referencing M:N on batches)
--    One row = "quantity_used_kg of PARENT went into CHILD"
--    Split : 1 parent -> many child rows
--    Merge : many parent -> 1 child rows
-- ---------------------------------------------------------------------
CREATE TABLE batch_lineage (
    parent_batch_id  INT UNSIGNED NOT NULL,
    child_batch_id   INT UNSIGNED NOT NULL,
    quantity_used_kg DECIMAL(12,3) NOT NULL,
    relation_type    ENUM('SPLIT','MERGE','PROCESS') NOT NULL,
    created_at       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (parent_batch_id, child_batch_id),      -- composite PK
    INDEX idx_lineage_parent (parent_batch_id),         -- REQUIRED INDEX
    INDEX idx_lineage_child (child_batch_id),           -- speeds upstream trace
    CONSTRAINT fk_lineage_parent FOREIGN KEY (parent_batch_id) REFERENCES batches (batch_id),
    CONSTRAINT fk_lineage_child  FOREIGN KEY (child_batch_id)  REFERENCES batches (batch_id),
    CONSTRAINT ck_lineage_qty    CHECK (quantity_used_kg > 0),
    CONSTRAINT ck_lineage_self   CHECK (parent_batch_id <> child_batch_id)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 8. processing_events
-- ---------------------------------------------------------------------
CREATE TABLE processing_events (
    event_id       INT UNSIGNED NOT NULL AUTO_INCREMENT,
    batch_id       INT UNSIGNED NOT NULL,
    unit_id        INT UNSIGNED NOT NULL,
    event_type     ENUM('WASHING','CLEANING','SORTING','DRYING','GRINDING',
                        'PACKING','SPLIT','MERGE') NOT NULL,
    input_qty_kg   DECIMAL(12,3) NOT NULL,
    output_qty_kg  DECIMAL(12,3) NOT NULL,
    event_time     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    performed_by   INT UNSIGNED NOT NULL,
    notes          VARCHAR(255) NULL,
    PRIMARY KEY (event_id),
    INDEX idx_events_batch (batch_id),
    INDEX idx_events_unit (unit_id),
    INDEX idx_events_user (performed_by),
    CONSTRAINT fk_events_batch FOREIGN KEY (batch_id)     REFERENCES batches (batch_id),
    CONSTRAINT fk_events_unit  FOREIGN KEY (unit_id)      REFERENCES processing_units (unit_id),
    CONSTRAINT fk_events_user  FOREIGN KEY (performed_by) REFERENCES users (user_id),
    CONSTRAINT ck_events_qty   CHECK (input_qty_kg > 0 AND output_qty_kg >= 0
                                      AND output_qty_kg <= input_qty_kg)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 9. inspections
-- ---------------------------------------------------------------------
CREATE TABLE inspections (
    inspection_id  INT UNSIGNED NOT NULL AUTO_INCREMENT,
    batch_id       INT UNSIGNED NOT NULL,
    inspector_id   INT UNSIGNED NOT NULL,
    inspected_at   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    test_type      VARCHAR(80) NOT NULL DEFAULT 'GENERAL',
    result         ENUM('PASS','FAIL') NOT NULL,
    remarks        VARCHAR(500) NULL,
    PRIMARY KEY (inspection_id),
    INDEX idx_inspections_batch_result (batch_id, result),   -- REQUIRED INDEX
    INDEX idx_inspections_inspector (inspector_id),
    CONSTRAINT fk_insp_batch     FOREIGN KEY (batch_id)     REFERENCES batches (batch_id),
    CONSTRAINT fk_insp_inspector FOREIGN KEY (inspector_id) REFERENCES users (user_id)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 10. inspection_parameters  (lab readings belonging to one inspection)
--     within_limit is a VIRTUAL generated column: computed, not stored,
--     so there is no redundancy and 3NF is preserved.
-- ---------------------------------------------------------------------
CREATE TABLE inspection_parameters (
    parameter_id    INT UNSIGNED NOT NULL AUTO_INCREMENT,
    inspection_id   INT UNSIGNED NOT NULL,
    parameter_name  VARCHAR(80)  NOT NULL,        -- e.g. Salmonella, Pesticide residue
    measured_value  DECIMAL(12,4) NOT NULL,
    limit_value     DECIMAL(12,4) NOT NULL,
    limit_type      ENUM('MAX','MIN') NOT NULL DEFAULT 'MAX',
    unit            VARCHAR(20) NOT NULL,
    within_limit    TINYINT(1) GENERATED ALWAYS AS (
                        CASE limit_type
                            WHEN 'MAX' THEN measured_value <= limit_value
                            ELSE measured_value >= limit_value
                        END) VIRTUAL,
    PRIMARY KEY (parameter_id),
    UNIQUE KEY uq_param_per_inspection (inspection_id, parameter_name),
    CONSTRAINT fk_param_inspection FOREIGN KEY (inspection_id)
        REFERENCES inspections (inspection_id) ON DELETE CASCADE,
    CONSTRAINT ck_param_values CHECK (measured_value >= 0 AND limit_value >= 0)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 11. shipments
-- ---------------------------------------------------------------------
CREATE TABLE shipments (
    shipment_id        INT UNSIGNED NOT NULL AUTO_INCREMENT,
    batch_id           INT UNSIGNED NOT NULL,
    retailer_id        INT UNSIGNED NOT NULL,        -- user with RETAILER role
    quantity_kg        DECIMAL(12,3) NOT NULL,
    shipped_date       DATE NOT NULL,
    expected_delivery  DATE NULL,
    status             ENUM('PENDING','IN_TRANSIT','DELIVERED','CANCELLED','RETURNED')
                           NOT NULL DEFAULT 'PENDING',
    confirmed_at       DATETIME NULL,
    created_by         INT UNSIGNED NOT NULL,
    created_at         DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (shipment_id),
    INDEX idx_shipments_batch (batch_id),                       -- REQUIRED INDEX
    INDEX idx_shipments_retailer_date (retailer_id, shipped_date),
    INDEX idx_shipments_status (status),
    INDEX idx_shipments_creator (created_by),
    CONSTRAINT fk_ship_batch    FOREIGN KEY (batch_id)    REFERENCES batches (batch_id),
    CONSTRAINT fk_ship_retailer FOREIGN KEY (retailer_id) REFERENCES users (user_id),
    CONSTRAINT fk_ship_creator  FOREIGN KEY (created_by)  REFERENCES users (user_id),
    CONSTRAINT ck_ship_qty      CHECK (quantity_kg > 0),
    CONSTRAINT ck_ship_dates    CHECK (expected_delivery IS NULL OR expected_delivery >= shipped_date),
    CONSTRAINT ck_ship_confirm  CHECK (status <> 'DELIVERED' OR confirmed_at IS NOT NULL)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 12. recalls
-- ---------------------------------------------------------------------
CREATE TABLE recalls (
    recall_id    INT UNSIGNED NOT NULL AUTO_INCREMENT,
    recall_code  VARCHAR(30) NOT NULL,
    batch_id     INT UNSIGNED NOT NULL,              -- the failing / origin batch
    issued_by    INT UNSIGNED NOT NULL,              -- Food Safety Officer
    severity     ENUM('CLASS_I','CLASS_II','CLASS_III') NOT NULL,
    reason       VARCHAR(500) NOT NULL,
    status       ENUM('OPEN','CLOSED') NOT NULL DEFAULT 'OPEN',
    issued_at    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    closed_at    DATETIME NULL,
    PRIMARY KEY (recall_id),
    UNIQUE KEY uq_recalls_code (recall_code),
    INDEX idx_recalls_batch (batch_id),
    INDEX idx_recalls_issuer (issued_by),
    CONSTRAINT fk_recalls_batch  FOREIGN KEY (batch_id)  REFERENCES batches (batch_id),
    CONSTRAINT fk_recalls_issuer FOREIGN KEY (issued_by) REFERENCES users (user_id),
    CONSTRAINT ck_recalls_close  CHECK (
        (status = 'OPEN'   AND closed_at IS NULL) OR
        (status = 'CLOSED' AND closed_at IS NOT NULL AND closed_at >= issued_at)
    )
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 13. audit_log  (append-only history written by triggers and the app)
-- ---------------------------------------------------------------------
CREATE TABLE audit_log (
    log_id        BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    table_name    VARCHAR(64) NOT NULL,
    record_id     BIGINT UNSIGNED NULL,
    action        ENUM('INSERT','UPDATE','DELETE','QUARANTINE','CANCEL_SHIPMENT',
                       'RECALL','LOGIN','OTHER') NOT NULL,
    details       JSON NULL,
    performed_by  INT UNSIGNED NULL,                 -- NULL when done by a trigger
    performed_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (log_id),
    INDEX idx_audit_table_record (table_name, record_id),
    INDEX idx_audit_time (performed_at),
    CONSTRAINT fk_audit_user FOREIGN KEY (performed_by) REFERENCES users (user_id)
        ON DELETE SET NULL
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- Quick sanity check after running:
--   SHOW TABLES;                     -- expect 13 tables
--   SHOW INDEX FROM batches;
--   SELECT table_name, constraint_name, constraint_type
--     FROM information_schema.table_constraints
--    WHERE table_schema = 'traceroot' ORDER BY table_name;
-- ---------------------------------------------------------------------
