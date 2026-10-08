# TraceRoot: Farm-to-Shelf Food Batch Tracking and Recall Management System

## Project Overview

TraceRoot is a DBMS-based food traceability and recall management system designed to track food batches from farms to retailers.

The system maintains the complete history of a food batch, including harvesting, processing, splitting, merging, inspection, shipment, and recall.

If a food batch fails a safety inspection, the system automatically quarantines the batch and prevents unsafe shipments. In case of a recall, TraceRoot can trace the affected batch back to its source farm and identify the retailers and other batches that may be affected.

## GitHub Repository

https://github.com/ashnasingh2909/TraceRoot

## Problem Statement

When contamination is detected in a food product, identifying its source and all affected destinations can take significant time.

TraceRoot solves this problem by maintaining batch lineage in a relational database. This enables fast upstream and downstream tracing and helps perform targeted recalls instead of recalling unrelated safe products.

## System Flow

Farm  
↓  
Food Batch  
↓  
Processing  
↓  
Split / Merge  
↓  
Inspection  
↓  
Shipment  
↓  
Retailer  

If contamination is detected:

Inspection FAIL  
↓  
Automatic Quarantine  
↓  
Shipment Blocked  
↓  
Recall Issued  
↓  
Trace Source Farm and Affected Retailers

## User Roles

### Admin
- Manages users and roles
- Has overall system access

### Farmer
- Manages farm information
- Creates harvest batches
- Views own batches

### Processor
- Records processing events
- Splits food batches
- Merges food batches
- Maintains batch lineage

### Inspector
- Performs batch inspections
- Records safety parameters
- Marks inspections as PASS or FAIL

### Retailer
- Receives shipments
- Views batch history and traceability information

### Food Safety Officer
- Issues food recalls
- Traces affected batches
- Identifies source farms and affected retailers
- Views recall reports

## Major DBMS Features

- 13 normalized database tables
- Primary and Foreign Keys
- 3NF Normalization
- Constraints
- CRUD Operations
- Multi-table JOINs
- Aggregate Queries
- Views
- Indexes
- Triggers
- Stored Procedures
- SQL Functions
- Transactions
- Recursive CTEs
- Role-Based Access Control

## Important Database Features

### Automatic Quarantine Trigger

When an inspection result is marked as FAIL, the database automatically quarantines the affected batch and cancels pending shipments.

### Unsafe Shipment Prevention

Quarantined, recalled, or expired batches are prevented from being shipped.

### Batch Split Transaction

Batch splitting is performed using a stored procedure with transaction handling and quantity validation.

### Recall Tracing

Recursive CTEs are used to trace:

- Upstream: Batch → Parent Batch → Source Farm
- Downstream: Batch → Derived Batches → Shipments → Retailers

### Batch Risk Score

A SQL function calculates a risk score from 0 to 100 using inspection failures, farm history, and batch status.

## Database Tables

1. roles
2. users
3. farms
4. products
5. batches
6. batch_lineage
7. processing_units
8. processing_events
9. inspections
10. inspection_parameters
11. shipments
12. recalls
13. audit_log

## Technology Stack

- Database: MySQL 8
- Backend: Python Flask
- ORM: SQLAlchemy
- Frontend: HTML, CSS, Bootstrap 5, Jinja2
- Authentication: Flask-Login
- Security: bcrypt, CSRF Protection, Parameterized Queries

## How to Run

### 1. Install dependencies

```bash
pip install -r requirements.txt
```

### 2. Configure database

Create a `.env` file and configure the MySQL credentials.

### 3. Create database schema

```bash
mysql -u root -p < schema.sql
```

### 4. Load database routines

```bash
mysql -u root -p traceroot < "routines (1).sql"
```

### 5. Load sample data

```bash
mysql -u root -p traceroot < seed_data.sql
```

### 6. Start the application

```bash
python run.py
```

Open:

http://localhost:5000

## Security

- Password hashing
- Role-Based Access Control
- Parameterized queries
- Session-based authentication
- CSRF protection
- Environment variables for sensitive credentials

## Conclusion

TraceRoot provides end-to-end food batch traceability from farm to retailer. By combining batch lineage, automated safety triggers, transactions, and recursive recall tracing, the system helps identify affected products quickly and supports targeted food recalls.