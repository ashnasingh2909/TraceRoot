from flask import Flask
from flask_sqlalchemy import SQLAlchemy
from flask_login import LoginManager
from sqlalchemy import inspect, text
from config import Config

db = SQLAlchemy()
login_manager = LoginManager()


def seed_default_data():
    from app.models import Role, User, Farm, Product, ProcessingUnit

    if Role.query.count() == 0:
        role_names = {
            1: 'ADMIN',
            2: 'FARMER',
            3: 'PROCESSOR',
            4: 'INSPECTOR',
            5: 'RETAILER',
            6: 'FOOD_SAFETY_OFFICER',
        }
        for role_id, role_name in role_names.items():
            db.session.add(Role(role_id=role_id, role_name=role_name, description=f'{role_name} role'))

    db.session.commit()

    if User.query.count() == 0:
        demo_users = [
            ('admin', 'admin@traceroot.com', 'System Administrator', 1),
            ('farmer_raj', 'raj@greenfield.com', 'Raj Kumar', 2),
            ('processor_ashok', 'ashok@spicepro.com', 'Ashok Patel', 3),
            ('inspector_meena', 'meena@fssai.gov', 'Meena Reddy', 4),
            ('retailer_freshmart', 'orders@freshmart.com', 'Vikram Singh', 5),
            ('fso_kumar', 'kumar@foodsafety.gov', 'Dr. Kumar Verma', 6),
        ]
        for username, email, full_name, role_id in demo_users:
            user = User(username=username, email=email, full_name=full_name, role_id=role_id, is_active=True)
            user.set_password('password123')
            db.session.add(user)

    db.session.commit()

    if Farm.query.count() == 0:
        farmer_raj = User.query.filter_by(username='farmer_raj').first()
        db.session.add_all([
            Farm(farm_code='FRM-GF-001', farm_name='Greenfield Turmeric Farm', owner_id=farmer_raj.user_id,
                 village='Sangli', district='Sangli', state='Maharashtra', area_acres=15.5, organic_certified=True),
            Farm(farm_code='FRM-OF-002', farm_name='Organic Spinach Gardens', owner_id=farmer_raj.user_id,
                 village='Nashik', district='Nashik', state='Maharashtra', area_acres=8.2, organic_certified=True),
            Farm(farm_code='FRM-GF-003', farm_name='Greenfield Coriander Farm', owner_id=farmer_raj.user_id,
                 village='Kolhapur', district='Kolhapur', state='Maharashtra', area_acres=12.0, organic_certified=False),
        ])

    if Product.query.count() == 0:
        db.session.add_all([
            Product(product_name='Turmeric', category='SPICE', shelf_life_days=180),
            Product(product_name='Spinach', category='LEAFY_VEGETABLE', shelf_life_days=7),
            Product(product_name='Coriander Leaves', category='LEAFY_VEGETABLE', shelf_life_days=5),
            Product(product_name='Chili Powder', category='SPICE', shelf_life_days=365),
            Product(product_name='Curry Leaves', category='LEAFY_VEGETABLE', shelf_life_days=4),
        ])

    if ProcessingUnit.query.count() == 0:
        processor = User.query.filter_by(username='processor_ashok').first()
        db.session.add(
            ProcessingUnit(
                unit_code='PU-SP-001',
                unit_name='SpicePro Processing Unit',
                location='Pune Industrial Area',
                fssai_license_no='FSSAI-100123456789',
                manager_id=processor.user_id if processor else None,
            )
        )

    db.session.commit()


def reconcile_failed_inspections():
    from app.models import Batch, BatchLineage, Farm, Inspection, Shipment

    failed_batch_ids = db.session.query(Inspection.batch_id).filter_by(result='FAIL').distinct().all()
    for (batch_id,) in failed_batch_ids:
        batch = db.session.get(Batch, batch_id)
        if batch is None:
            continue

        if batch.status == 'ACTIVE':
            batch.status = 'QUARANTINED'
        Shipment.query.filter_by(batch_id=batch_id, status='PENDING').update(
            {'status': 'CANCELLED'},
            synchronize_session=False,
        )

        visited_batch_ids = set()
        pending_batch_ids = [batch_id]
        while pending_batch_ids:
            current_id = pending_batch_ids.pop()
            if current_id in visited_batch_ids:
                continue
            visited_batch_ids.add(current_id)
            current_batch = db.session.get(Batch, current_id)
            if current_batch and current_batch.farm_id is not None:
                Farm.query.filter_by(farm_id=current_batch.farm_id).update(
                    {'status': 'QUARANTINED'},
                    synchronize_session=False,
                )
            parents = db.session.query(BatchLineage.parent_batch_id).filter(
                BatchLineage.child_batch_id == current_id
            ).all()
            pending_batch_ids.extend(parent_id for (parent_id,) in parents)

    db.session.commit()


def reconcile_open_recalls():
    from app.main.routes import apply_recall_to_batch_family
    from app.models import Recall

    open_recalls = Recall.query.filter_by(status='OPEN').order_by(Recall.recall_id).all()
    for recall in open_recalls:
        apply_recall_to_batch_family(
            recall.batch_id,
            recall.recall_id,
            recall.reason,
            recall.issued_by,
        )

    db.session.commit()


def create_app(config_class=Config):
    app = Flask(__name__)
    app.config.from_object(config_class)

    # Initialize extensions
    db.init_app(app)
    login_manager.init_app(app)
    login_manager.login_view = 'auth.login'
    login_manager.login_message = 'Please log in to access this page.'

    # Register blueprints
    from app.auth import bp as auth_bp
    app.register_blueprint(auth_bp, url_prefix='/auth')

    from app.main import bp as main_bp
    app.register_blueprint(main_bp)

    from app.api import bp as api_bp
    app.register_blueprint(api_bp, url_prefix='/api')

    # Create tables
    with app.app_context():
        db.create_all()
        farm_columns = {column['name'] for column in inspect(db.engine).get_columns('farms')}
        if 'status' not in farm_columns:
            with db.engine.begin() as connection:
                connection.exec_driver_sql(
                    "ALTER TABLE farms ADD COLUMN status VARCHAR(20) NOT NULL DEFAULT 'ACTIVE'"
                )
        inspection_columns = {column['name'] for column in inspect(db.engine).get_columns('inspections')}
        if 'test_type' not in inspection_columns:
            with db.engine.begin() as connection:
                connection.exec_driver_sql(
                    "ALTER TABLE inspections ADD COLUMN test_type VARCHAR(80) NOT NULL DEFAULT 'GENERAL'"
                )

        db.session.execute(text(
            'CREATE TABLE IF NOT EXISTS app_migrations '
            '(migration_key VARCHAR(100) PRIMARY KEY, applied_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP)'
        ))
        quarantine_migration = db.session.execute(
            text('SELECT migration_key FROM app_migrations WHERE migration_key = :key'),
            {'key': 'reconcile_failed_inspections_v1'},
        ).first()
        if quarantine_migration is None:
            reconcile_failed_inspections()
            db.session.execute(
                text('INSERT INTO app_migrations (migration_key) VALUES (:key)'),
                {'key': 'reconcile_failed_inspections_v1'},
            )
            db.session.commit()

        recall_migration = db.session.execute(
            text('SELECT migration_key FROM app_migrations WHERE migration_key = :key'),
            {'key': 'cascade_existing_open_recalls_v1'},
        ).first()
        if recall_migration is None:
            reconcile_open_recalls()
            db.session.execute(
                text('INSERT INTO app_migrations (migration_key) VALUES (:key)'),
                {'key': 'cascade_existing_open_recalls_v1'},
            )
            db.session.commit()

        seed_default_data()

    return app
