# TraceRoot: Farm-to-Shelf Food Batch Tracking and Recall Management System

A complete DBMS hackathon project demonstrating advanced database concepts including triggers, stored procedures, recursive CTEs, views, functions, and role-based access control.

## 🎯 Features

- **Complete Traceability**: Track every food batch from harvest through splits, merges, processing, and shipments
- **Instant Recalls**: Identify all affected farms, batches, and retailers in seconds using recursive CTEs
- **Role-Based Access Control**: 6 user roles (Admin, Farmer, Processor, Inspector, Retailer, Food Safety Officer)
- **Automated Safety**: Triggers auto-quarantine failed batches and block unsafe shipments
- **Transaction Safety**: Batch splits use transactions with rollback on errors

## 🛠 Tech Stack

- **Database**: MySQL 8.0+
- **Backend**: Python Flask with blueprints and app factory pattern
- **ORM**: SQLAlchemy (with raw SQL for recursive CTEs and stored procedures)
- **Frontend**: HTML, CSS, Bootstrap 5, Jinja2 templates
- **Security**: bcrypt password hashing, .env for credentials, parameterized queries, session-based login, CSRF protection

## 📊 Database Schema (13 Tables in 3NF)

- `roles` - RBAC lookup
- `users` - User accounts with role assignments
- `farms` - Farm information
- `products` - Product catalog (spices, leafy vegetables)
- `batches` - Food batches with lineage tracking
- `batch_lineage` - Batch family tree (splits, merges)
- `processing_units` - Processing facilities
- `processing_events` - Processing operations
- `inspections` - Quality inspections
- `inspection_parameters` - Lab test results
- `shipments` - Batch shipments to retailers
- `recalls` - Recall records
- `audit_log` - System audit trail

## 🚀 DBMS Features Demonstrated

### 1. Triggers
- **trg_inspection_fail_quarantine**: Auto-quarantines batch on failed inspection, cancels pending shipments, writes to audit log
- **trg_shipment_block_unsafe**: Prevents shipping of QUARANTINED, RECALLED, or expired batches

### 2. Stored Procedures
- **sp_split_batch**: Transactional batch split with row locking, quantity validation, and automatic shipment creation
- **sp_trace_recall**: Uses recursive CTE to trace upstream (farms) and downstream (retailers) impact with cycle guard

### 3. Functions
- **fn_batch_risk_score**: Calculates risk score (0-100) based on inspection failures, farm history, and batch status

### 4. Views
- **v_batch_trace_summary**: Comprehensive batch view with lineage, inspections, shipments, and risk score
- **v_recall_impact**: Recall impact analysis using recursive CTEs

### 5. Constraints
- Primary Keys, Foreign Keys, UNIQUE, NOT NULL
- CHECK constraints (quantity ranges, date logic, status transitions)
- ENUM constraints (status, stage, result, severity)
- 3NF normalization

### 6. Indexes
- `batches(farm_id)`, `batch_lineage(parent_batch_id)`, `shipments(batch_id)`, `inspections(batch_id, result)`

### 7. Queries
- JOIN queries (multi-table joins)
- Aggregate queries with HAVING (farm failure rates)
- Recursive CTEs (batch lineage tree)
- Search and filter with parameterized queries

## 📦 Installation

### Prerequisites
- Python 3.8+
- MySQL 8.0+
- pip

### Setup Steps

1. **Clone the repository**
```bash
cd dbthon
```

2. **Install Python dependencies**
```bash
pip install -r requirements.txt
```

3. **Configure MySQL database**
```bash
# Create .env file from example
copy .env.example .env

# Edit .env with your MySQL credentials
# DB_HOST=localhost
# DB_PORT=3306
# DB_USER=root
# DB_PASSWORD=your_password
# DB_NAME=traceroot
```

4. **Run database setup scripts in order**
```bash
# Phase 1: Create schema
mysql -u root -p < schema.sql

# Phase 2: Create triggers, procedures, functions, views
mysql -u root -p traceroot < "routines (1).sql"

# Phase 3: Load seed data
mysql -u root -p traceroot < seed_data.sql
```

5. **Run the Flask application**
```bash
python run.py
```

6. **Access the application**
```
http://localhost:5000
```

## 👥 Demo Credentials

All accounts use password: `password123`

| Role | Username | Description |
|------|----------|-------------|
| Admin | admin | Full system access, manage users |
| Farmer | farmer_raj | Own farms and create harvest batches |
| Processor | processor_ashok | Split/merge batches, log processing |
| Inspector | inspector_meena | Record inspections and test results |
| Retailer | retailer_freshmart | Receive shipments, view batch history |
| Food Safety Officer | fso_kumar | Issue recalls, view reports |

## 📁 Project Structure

```
dbthon/
├── app/
│   ├── __init__.py          # App factory
│   ├── models.py            # SQLAlchemy models (13 tables)
│   ├── auth/                # Authentication blueprint
│   │   ├── __init__.py
│   │   ├── routes.py        # Login/logout
│   │   └── decorators.py    # Role-based access decorators
│   ├── main/                # Main routes blueprint
│   │   ├── __init__.py
│   │   └── routes.py        # All CRUD routes
│   ├── api/                 # API blueprint
│   │   ├── __init__.py
│   │   └── routes.py        # JSON API endpoints
│   └── templates/           # Jinja2 templates
│       ├── base.html        # Base template with Bootstrap
│       ├── index.html       # Landing page
│       ├── auth/            # Auth templates
│       ├── dashboard/       # Role-specific dashboards
│       ├── farmer/          # Farmer templates
│       ├── processor/       # Processor templates
│       ├── inspector/      # Inspector templates
│       ├── retailer/        # Retailer templates
│       ├── fso/             # Food Safety Officer templates
│       ├── admin/           # Admin templates
│       ├── batches/         # Batch listing/detail
│       ├── recall/          # Recall simulation
│       └── reports/         # Analytics reports
├── schema.sql               # Phase 1: Database schema
├── routines (1).sql         # Phase 2: Triggers, procedures, functions, views
├── seed_data.sql            # Phase 3: Sample data
├── queries.sql              # Demo queries
├── requirements.txt         # Python dependencies
├── .env.example             # Environment variables template
├── config.py                # Configuration
├── run.py                   # Application entry point
└── README.md                # This file
```

## 🎓 DBMS Concepts for Viva

### Triggers
- **Purpose**: Automatically execute actions in response to database events
- **This project**: Auto-quarantine on inspection failure, block unsafe shipments
- **Key point**: Runs in same transaction as triggering event

### Stored Procedures
- **Purpose**: Encapsulate complex business logic on database server
- **This project**: sp_split_batch (transactional split), sp_trace_recall (recursive trace)
- **Key point**: Reduces network round trips, ensures data integrity

### Recursive CTEs
- **Purpose**: Query hierarchical data (trees, graphs)
- **This project**: Trace batch lineage upstream and downstream
- **Key point**: Cycle guard prevents infinite loops

### Views
- **Purpose**: Virtual tables based on query results
- **This project**: v_batch_trace_summary, v_recall_impact
- **Key point**: Simplifies complex queries, provides security layer

### Functions
- **Purpose**: Reusable scalar computations
- **This project**: fn_batch_risk_score
- **Key point**: Can be used in queries, computed per row

### Transactions
- **Purpose**: Ensure atomicity of multiple operations
- **This project**: Batch split (insert children, lineage, shipments, update parent)
- **Key point**: COMMIT if all succeed, ROLLBACK if any fail

### Normalization (3NF)
- **Purpose**: Eliminate redundancy and ensure data integrity
- **This project**: All tables in 3NF, derived batches have NULL farm_id (found via lineage)
- **Key point**: No transitive dependencies

### Indexes
- **Purpose**: Speed up query performance
- **This project**: Indexes on foreign keys and frequently queried columns
- **Key point**: Trade-off between read speed and write speed/storage

## 🔒 Security Features

- **Password Hashing**: bcrypt for secure password storage
- **Role-Based Access Control**: 6 roles with specific permissions
- **Parameterized Queries**: SQLAlchemy ORM prevents SQL injection
- **Session-Based Authentication**: Flask-Login for secure sessions
- **CSRF Protection**: Flask-WTF forms include CSRF tokens
- **Environment Variables**: Sensitive data in .env file

## 📝 Seed Data

The seed data includes:
- 9 users across all 6 roles
- 3 farms (turmeric, spinach, coriander)
- 5 products (spices and leafy vegetables)
- 1 processing unit
- 7 batches including:
  - 1 batch split into 3 children
  - 2 batches merged into 1
  - 1 failed inspection triggering quarantine
  - 1 recall issued
- 3 shipments
- 3 inspections with parameters

## 🎨 UI Features

- Modern Bootstrap 5 interface
- Gradient color schemes
- Responsive design
- Role-specific dashboards
- Interactive batch trace visualization
- Real-time statistics
- Search and filter functionality

## 🏆 Hackathon Tips

1. **Demonstrate the Recall Simulation** - Show batch ID 3 to see the full trace
2. **Explain the Trigger** - Create a failed inspection to see auto-quarantine
3. **Show the Split** - Use processor role to split a batch with transaction safety
4. **Discuss the Schema** - Explain 3NF and why derived batches have NULL farm_id
5. **Highlight Security** - Mention bcrypt, RBAC, and parameterized queries


