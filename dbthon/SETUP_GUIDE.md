# Quick Setup Guide

## Step 1: Install Python Dependencies
```bash
pip install -r requirements.txt
```

## Step 2: Configure Database
```bash
# Copy the example env file
copy .env.example .env

# Edit .env with your MySQL credentials
# Notepad .env
```

Edit `.env` file:
```
DB_HOST=localhost
DB_PORT=3306
DB_USER=root
DB_PASSWORD=your_mysql_password
DB_NAME=traceroot
SECRET_KEY=your-secret-key-here
```

## Step 3: Run Database Scripts (in order)

```bash
# 1. Create database and schema
mysql -u root -p < schema.sql

# 2. Create triggers, procedures, functions, views
mysql -u root -p traceroot < "routines (1).sql"

# 3. Load seed data
mysql -u root -p traceroot < seed_data.sql
```

## Step 4: Run the Application
```bash
python run.py
```

## Step 5: Access the Application
Open browser: http://localhost:5000

## Demo Credentials (password: password123)
- Admin: admin
- Farmer: farmer_raj
- Processor: processor_ashok
- Inspector: inspector_meena
- Retailer: retailer_freshmart
- Food Safety Officer: fso_kumar

## Key Features to Demonstrate

1. **Recall Simulation**: Login as FSO, go to Recall Simulation, enter batch ID 3
2. **Batch Split**: Login as Processor, go to batches, split a batch
3. **Inspection**: Login as Inspector, create an inspection with FAIL result
4. **Dashboard**: Each role has a customized dashboard

## Troubleshooting

**MySQL Connection Error**: Check your MySQL credentials in .env
**Module Not Found**: Run `pip install -r requirements.txt`
**Database Not Found**: Run the SQL scripts in order
