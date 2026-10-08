-- =====================================================================
-- TraceRoot | Phase 3: seed data (spices and leafy vegetables)
-- Run AFTER schema.sql and routines.sql:
--     mysql -u root -p traceroot < seed_data.sql
-- =====================================================================
USE traceroot;

-- ---------------------------------------------------------------------
-- 1. Roles
-- ---------------------------------------------------------------------
INSERT INTO roles (role_id, role_name, description) VALUES
(1, 'ADMIN', 'Full system access, manage users'),
(2, 'FARMER', 'Own farms and create harvest batches'),
(3, 'PROCESSOR', 'Split/merge batches, log processing events'),
(4, 'INSPECTOR', 'Record inspections and test results'),
(5, 'RETAILER', 'Receive shipments, view batch history'),
(6, 'FOOD_SAFETY_OFFICER', 'Issue recalls, view reports');

-- ---------------------------------------------------------------------
-- 2. Users (passwords are bcrypt hashes: 'password123' for all)
-- ---------------------------------------------------------------------
INSERT INTO users (user_id, username, email, password_hash, full_name, phone, role_id, shop_name, city) VALUES
-- Admin
(1, 'admin', 'admin@traceroot.com', '$2b$12$LQv3c1yqBWVHxkd0LHAkCOYz6TtxMQJqhN8/LewY5GyYkGhW2fD6i', 'System Administrator', '9876543210', 1, NULL, NULL),
-- Farmers
(2, 'farmer_raj', 'raj@greenfield.com', '$2b$12$LQv3c1yqBWVHxkd0LHAkCOYz6TtxMQJqhN8/LewY5GyYkGhW2fD6i', 'Raj Kumar', '9988776655', 2, NULL, NULL),
(3, 'farmer_priya', 'priya@organicfarms.com', '$2b$12$LQv3c1yqBWVHxkd0LHAkCOYz6TtxMQJqhN8/LewY5GyYkGhW2fD6i', 'Priya Sharma', '9977665544', 2, NULL, NULL),
-- Processors
(4, 'processor_ashok', 'ashok@spicepro.com', '$2b$12$LQv3c1yqBWVHxkd0LHAkCOYz6TtxMQJqhN8/LewY5GyYkGhW2fD6i', 'Ashok Patel', '9966554433', 3, NULL, NULL),
-- Inspectors
(5, 'inspector_meena', 'meena@fssai.gov', '$2b$12$LQv3c1yqBWVHxkd0LHAkCOYz6TtxMQJqhN8/LewY5GyYkGhW2fD6i', 'Meena Reddy', '9955443322', 4, NULL, NULL),
-- Retailers
(6, 'retailer_freshmart', 'orders@freshmart.com', '$2b$12$LQv3c1yqBWVHxkd0LHAkCOYz6TtxMQJqhN8/LewY5GyYkGhW2fD6i', 'Vikram Singh', '9944332211', 5, 'FreshMart Supermarket', 'Mumbai'),
(7, 'retailer_greenbasket', 'contact@greenbasket.com', '$2b$12$LQv3c1yqBWVHxkd0LHAkCOYz6TtxMQJqhN8/LewY5GyYkGhW2fD6i', 'Anita Desai', '9933221100', 5, 'GreenBasket Stores', 'Delhi'),
(8, 'retailer_spiceworld', 'sales@spiceworld.com', '$2b$12$LQv3c1yqBWVHxkd0LHAkCOYz6TtxMQJqhN8/LewY5GyYkGhW2fD6i', 'Rahul Menon', '9922110099', 5, 'SpiceWorld Emporium', 'Bangalore'),
-- Food Safety Officer
(9, 'fso_kumar', 'kumar@foodsafety.gov', '$2b$12$LQv3c1yqBWVHxkd0LHAkCOYz6TtxMQJqhN8/LewY5GyYkGhW2fD6i', 'Dr. Kumar Verma', '9911009887', 6, NULL, NULL);

-- ---------------------------------------------------------------------
-- 3. Farms
-- ---------------------------------------------------------------------
INSERT INTO farms (farm_id, farm_code, farm_name, owner_id, village, district, state, area_acres, organic_certified) VALUES
(1, 'FRM-GF-001', 'Greenfield Turmeric Farm', 2, 'Sangli', 'Sangli', 'Maharashtra', 15.5, 1),
(2, 'FRM-OF-002', 'Organic Spinach Gardens', 3, 'Nashik', 'Nashik', 'Maharashtra', 8.2, 1),
(3, 'FRM-GF-003', 'Greenfield Coriander Farm', 2, 'Kolhapur', 'Kolhapur', 'Maharashtra', 12.0, 0);

-- ---------------------------------------------------------------------
-- 4. Products (spices and leafy vegetables)
-- ---------------------------------------------------------------------
INSERT INTO products (product_id, product_name, category, shelf_life_days) VALUES
(1, 'Turmeric', 'SPICE', 180),
(2, 'Spinach', 'LEAFY_VEGETABLE', 7),
(3, 'Coriander Leaves', 'LEAFY_VEGETABLE', 5),
(4, 'Chili Powder', 'SPICE', 365),
(5, 'Curry Leaves', 'LEAFY_VEGETABLE', 4);

-- ---------------------------------------------------------------------
-- 5. Processing Units
-- ---------------------------------------------------------------------
INSERT INTO processing_units (unit_id, unit_code, unit_name, location, fssai_license_no, manager_id) VALUES
(1, 'PU-SP-001', 'SpicePro Processing Unit', 'Pune Industrial Area', 'FSSAI-100123456789', 4);

-- ---------------------------------------------------------------------
-- 6. Batches (HARVEST batches from farms)
-- ---------------------------------------------------------------------
INSERT INTO batches (batch_id, batch_code, product_id, batch_type, farm_id, processing_unit_id, 
                     initial_quantity_kg, quantity_kg, harvest_date, expiry_date, status, stage, created_by) VALUES
-- Turmeric harvest from Greenfield
(1, 'BATCH-TUR-2024-001', 1, 'HARVEST', 1, NULL, 500.000, 500.000, '2024-01-15', '2024-07-15', 'ACTIVE', 'HARVESTED', 2),
-- Spinach harvest from Organic Gardens
(2, 'BATCH-SPN-2024-001', 2, 'HARVEST', 2, NULL, 200.000, 200.000, '2024-02-01', '2024-02-08', 'ACTIVE', 'HARVESTED', 3),
-- Coriander harvest from Greenfield
(3, 'BATCH-COR-2024-001', 3, 'HARVEST', 3, NULL, 150.000, 150.000, '2024-02-05', '2024-02-10', 'ACTIVE', 'HARVESTED', 2);

-- ---------------------------------------------------------------------
-- 7. Processing Events (washing, cleaning, etc.)
-- ---------------------------------------------------------------------
INSERT INTO processing_events (batch_id, unit_id, event_type, input_qty_kg, output_qty_kg, performed_by, notes) VALUES
(1, 1, 'WASHING', 500.000, 495.000, 4, 'Initial wash of turmeric rhizomes'),
(1, 1, 'DRYING', 495.000, 480.000, 4, 'Sun drying for 7 days'),
(2, 1, 'WASHING', 200.000, 195.000, 4, 'Triple wash for spinach'),
(3, 1, 'CLEANING', 150.000, 148.000, 4, 'Remove damaged leaves');

-- ---------------------------------------------------------------------
-- 8. Batch Lineage - SPLIT scenario
-- Batch 1 (Turmeric 500kg) splits into 3 child batches: 200kg, 150kg, 130kg
-- Remaining 20kg consumed in processing
-- ---------------------------------------------------------------------
INSERT INTO batches (batch_id, batch_code, product_id, batch_type, farm_id, processing_unit_id,
                     initial_quantity_kg, quantity_kg, harvest_date, expiry_date, status, stage, created_by) VALUES
(4, 'BATCH-TUR-2024-001-S1', 1, 'DERIVED', NULL, 1, 200.000, 200.000, '2024-01-15', '2024-07-15', 'ACTIVE', 'PACKED', 4),
(5, 'BATCH-TUR-2024-001-S2', 1, 'DERIVED', NULL, 1, 150.000, 150.000, '2024-01-15', '2024-07-15', 'ACTIVE', 'PACKED', 4),
(6, 'BATCH-TUR-2024-001-S3', 1, 'DERIVED', NULL, 1, 130.000, 130.000, '2024-01-15', '2024-07-15', 'ACTIVE', 'PACKED', 4);

INSERT INTO batch_lineage (parent_batch_id, child_batch_id, quantity_used_kg, relation_type) VALUES
(1, 4, 200.000, 'SPLIT'),
(1, 5, 150.000, 'SPLIT'),
(1, 6, 130.000, 'SPLIT');

-- Update parent batch quantity after split
UPDATE batches SET quantity_kg = 20.000, status = 'CONSUMED' WHERE batch_id = 1;

-- ---------------------------------------------------------------------
-- 9. Batch Lineage - MERGE scenario
-- Batch 4 (200kg turmeric) and Batch 5 (150kg turmeric) merge into Batch 7
-- ---------------------------------------------------------------------
INSERT INTO batches (batch_id, batch_code, product_id, batch_type, farm_id, processing_unit_id,
                     initial_quantity_kg, quantity_kg, harvest_date, expiry_date, status, stage, created_by) VALUES
(7, 'BATCH-TUR-2024-001-M1', 1, 'DERIVED', NULL, 1, 350.000, 350.000, '2024-01-15', '2024-07-15', 'ACTIVE', 'PACKED', 4);

INSERT INTO batch_lineage (parent_batch_id, child_batch_id, quantity_used_kg, relation_type) VALUES
(4, 7, 200.000, 'MERGE'),
(5, 7, 150.000, 'MERGE');

-- Update parent batches after merge
UPDATE batches SET quantity_kg = 0, status = 'CONSUMED' WHERE batch_id IN (4, 5);

-- ---------------------------------------------------------------------
-- 10. Inspections (one PASS, one FAIL to trigger quarantine)
-- ---------------------------------------------------------------------
INSERT INTO inspections (inspection_id, batch_id, inspector_id, result, remarks) VALUES
(1, 2, 5, 'PASS', 'All parameters within limits'),
(2, 3, 5, 'FAIL', 'Pesticide residue exceeds maximum limit'),
(3, 6, 5, 'PASS', 'Quality standards met');

-- ---------------------------------------------------------------------
-- 11. Inspection Parameters (lab readings)
-- ---------------------------------------------------------------------
INSERT INTO inspection_parameters (inspection_id, parameter_name, measured_value, limit_value, limit_type, unit) VALUES
-- Inspection 1 (Spinach - PASS)
(1, 'Salmonella', 0.0000, 0.0000, 'MAX', 'CFU/g'),
(1, 'E. coli', 10.0000, 100.0000, 'MAX', 'CFU/g'),
(1, 'Pesticide Residue', 0.0500, 0.5000, 'MAX', 'mg/kg'),
-- Inspection 2 (Coriander - FAIL)
(2, 'Salmonella', 0.0000, 0.0000, 'MAX', 'CFU/g'),
(2, 'Pesticide Residue', 0.8500, 0.5000, 'MAX', 'mg/kg'),
(2, 'Heavy Metals', 0.0200, 0.0500, 'MAX', 'mg/kg'),
-- Inspection 3 (Turmeric S3 - PASS)
(3, 'Moisture Content', 9.5000, 12.0000, 'MAX', '%'),
(3, 'Aflatoxin', 0.0050, 0.0100, 'MAX', 'mg/kg');

-- ---------------------------------------------------------------------
-- 12. Shipments
-- ---------------------------------------------------------------------
INSERT INTO shipments (shipment_id, batch_id, retailer_id, quantity_kg, shipped_date, expected_delivery, status, created_by) VALUES
(1, 6, 6, 130.000, '2024-02-10', '2024-02-12', 'DELIVERED', 4),
(2, 7, 7, 200.000, '2024-02-12', '2024-02-14', 'IN_TRANSIT', 4),
(3, 2, 8, 100.000, '2024-02-05', '2024-02-07', 'DELIVERED', 4);

-- Update shipment 1 as delivered
UPDATE shipments SET confirmed_at = '2024-02-12 14:30:00' WHERE shipment_id = 1;

-- ---------------------------------------------------------------------
-- 13. Recall (for the failed coriander batch)
-- ---------------------------------------------------------------------
INSERT INTO recalls (recall_id, recall_code, batch_id, issued_by, severity, reason, status) VALUES
(1, 'REC-2024-001', 3, 9, 'CLASS_II', 'Pesticide residue exceeds safe limits detected in inspection', 'OPEN');

-- Update batch status to RECALLED
UPDATE batches SET status = 'RECALLED' WHERE batch_id = 3;

-- ---------------------------------------------------------------------
-- 14. Audit Log entries
-- ---------------------------------------------------------------------
INSERT INTO audit_log (table_name, record_id, action, details, performed_by) VALUES
('batches', 1, 'INSERT', JSON_OBJECT('batch_code', 'BATCH-TUR-2024-001', 'quantity_kg', 500), 2),
('batches', 3, 'UPDATE', JSON_OBJECT('status', 'RECALLED', 'reason', 'Inspection failure'), 9),
('recalls', 1, 'RECALL', JSON_OBJECT('recall_code', 'REC-2024-001', 'severity', 'CLASS_II'), 9);

-- ---------------------------------------------------------------------
-- Verification queries (run these to check data)
-- ---------------------------------------------------------------------
-- SELECT * FROM v_batch_trace_summary ORDER BY batch_id;
-- SELECT * FROM v_recall_impact;
-- CALL sp_trace_recall(3);
-- SELECT fn_batch_risk_score(3);
-- SELECT * FROM batches WHERE status = 'QUARANTINED';
-- SELECT * FROM shipments WHERE status = 'CANCELLED';
