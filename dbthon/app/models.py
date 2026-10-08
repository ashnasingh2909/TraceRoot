from datetime import datetime
from decimal import Decimal as PythonDecimal
from flask_sqlalchemy import SQLAlchemy
from flask_login import UserMixin
from werkzeug.security import generate_password_hash, check_password_hash
from sqlalchemy import Numeric
from app import db, login_manager

@login_manager.user_loader
def load_user(user_id):
    return User.query.get(int(user_id))

class Role(db.Model):
    __tablename__ = 'roles'
    
    role_id = db.Column(db.SmallInteger, primary_key=True)
    role_name = db.Column(db.Enum('ADMIN', 'FARMER', 'PROCESSOR', 'INSPECTOR', 'RETAILER', 'FOOD_SAFETY_OFFICER'), 
                         nullable=False, unique=True)
    description = db.Column(db.String(255))
    
    users = db.relationship('User', backref='role', lazy=True)

class User(UserMixin, db.Model):
    __tablename__ = 'users'
    
    user_id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(50), nullable=False, unique=True)
    email = db.Column(db.String(120), nullable=False, unique=True)
    password_hash = db.Column(db.String(255), nullable=False)
    full_name = db.Column(db.String(100), nullable=False)
    phone = db.Column(db.String(20))
    role_id = db.Column(db.SmallInteger, db.ForeignKey('roles.role_id'), nullable=False)
    shop_name = db.Column(db.String(120))
    city = db.Column(db.String(80))
    is_active = db.Column(db.Boolean, nullable=False, default=True)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    
    # Relationships
    owned_farms = db.relationship('Farm', backref='owner', lazy=True)
    managed_units = db.relationship('ProcessingUnit', backref='manager', lazy=True)
    performed_inspections = db.relationship('Inspection', backref='inspector', lazy=True)
    created_batches = db.relationship('Batch', backref='creator', lazy=True)
    created_shipments = db.relationship('Shipment', foreign_keys='Shipment.created_by', backref=db.backref('creator', foreign_keys='Shipment.created_by'), lazy=True)
    received_shipments = db.relationship('Shipment', foreign_keys='Shipment.retailer_id', backref='retailer', lazy=True)
    issued_recalls = db.relationship('Recall', backref='issuer', lazy=True)
    
    @property
    def id(self):
        return self.user_id

    def set_password(self, password):
        self.password_hash = generate_password_hash(password)

    def check_password(self, password):
        return check_password_hash(self.password_hash, password)

    def is_admin(self):
        return self.role and self.role.role_name == 'ADMIN'
    
    def is_farmer(self):
        return self.role and self.role.role_name == 'FARMER'
    
    def is_processor(self):
        return self.role and self.role.role_name == 'PROCESSOR'
    
    def is_inspector(self):
        return self.role and self.role.role_name == 'INSPECTOR'
    
    def is_retailer(self):
        return self.role and self.role.role_name == 'RETAILER'
    
    def is_food_safety_officer(self):
        return self.role and self.role.role_name == 'FOOD_SAFETY_OFFICER'

class Farm(db.Model):
    __tablename__ = 'farms'
    
    farm_id = db.Column(db.Integer, primary_key=True)
    farm_code = db.Column(db.String(20), nullable=False, unique=True)
    farm_name = db.Column(db.String(120), nullable=False)
    owner_id = db.Column(db.Integer, db.ForeignKey('users.user_id'), nullable=False)
    village = db.Column(db.String(80))
    district = db.Column(db.String(80), nullable=False)
    state = db.Column(db.String(80), nullable=False)
    area_acres = db.Column(Numeric(8, 2), nullable=False)
    organic_certified = db.Column(db.Boolean, nullable=False, default=False)
    status = db.Column(db.Enum('ACTIVE', 'QUARANTINED'), nullable=False, default='ACTIVE')
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    
    batches = db.relationship('Batch', backref='farm', lazy=True)

class Product(db.Model):
    __tablename__ = 'products'
    
    product_id = db.Column(db.Integer, primary_key=True)
    product_name = db.Column(db.String(100), nullable=False, unique=True)
    category = db.Column(db.Enum('SPICE', 'LEAFY_VEGETABLE', 'OTHER'), nullable=False)
    shelf_life_days = db.Column(db.SmallInteger, nullable=False)
    
    batches = db.relationship('Batch', backref='product', lazy=True)

class ProcessingUnit(db.Model):
    __tablename__ = 'processing_units'
    
    unit_id = db.Column(db.Integer, primary_key=True)
    unit_code = db.Column(db.String(20), nullable=False, unique=True)
    unit_name = db.Column(db.String(120), nullable=False)
    location = db.Column(db.String(150), nullable=False)
    fssai_license_no = db.Column(db.String(30), nullable=False, unique=True)
    manager_id = db.Column(db.Integer, db.ForeignKey('users.user_id'))
    
    processed_batches = db.relationship('Batch', backref='processing_unit', lazy=True)
    processing_events = db.relationship('ProcessingEvent', backref='unit', lazy=True)

class Batch(db.Model):
    __tablename__ = 'batches'
    
    batch_id = db.Column(db.Integer, primary_key=True)
    batch_code = db.Column(db.String(30), nullable=False, unique=True)
    product_id = db.Column(db.Integer, db.ForeignKey('products.product_id'), nullable=False)
    batch_type = db.Column(db.Enum('HARVEST', 'DERIVED'), nullable=False, default='HARVEST')
    farm_id = db.Column(db.Integer, db.ForeignKey('farms.farm_id'))
    processing_unit_id = db.Column(db.Integer, db.ForeignKey('processing_units.unit_id'))
    initial_quantity_kg = db.Column(Numeric(12, 3), nullable=False)
    quantity_kg = db.Column(Numeric(12, 3), nullable=False)
    harvest_date = db.Column(db.Date, nullable=False)
    expiry_date = db.Column(db.Date, nullable=False)
    status = db.Column(db.Enum('ACTIVE', 'QUARANTINED', 'RECALLED', 'CONSUMED', 'EXPIRED'), 
                       nullable=False, default='ACTIVE')
    stage = db.Column(db.Enum('HARVESTED', 'PROCESSING', 'PACKED', 'SHIPPED'), 
                     nullable=False, default='HARVESTED')
    created_by = db.Column(db.Integer, db.ForeignKey('users.user_id'), nullable=False)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow, onupdate=datetime.utcnow)
    
    # Relationships
    inspections = db.relationship('Inspection', backref='batch', lazy=True)
    shipments = db.relationship('Shipment', backref='batch', lazy=True)
    parent_lineage = db.relationship('BatchLineage', foreign_keys='BatchLineage.child_batch_id', 
                                    backref='child_batch', lazy=True)
    child_lineage = db.relationship('BatchLineage', foreign_keys='BatchLineage.parent_batch_id', 
                                   backref='parent_batch', lazy=True)
    processing_events = db.relationship('ProcessingEvent', backref='batch', lazy=True)
    recalls = db.relationship('Recall', backref='batch', lazy=True)

class BatchLineage(db.Model):
    __tablename__ = 'batch_lineage'
    
    parent_batch_id = db.Column(db.Integer, db.ForeignKey('batches.batch_id'), primary_key=True)
    child_batch_id = db.Column(db.Integer, db.ForeignKey('batches.batch_id'), primary_key=True)
    quantity_used_kg = db.Column(Numeric(12, 3), nullable=False)
    relation_type = db.Column(db.Enum('SPLIT', 'MERGE', 'PROCESS'), nullable=False)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

class ProcessingEvent(db.Model):
    __tablename__ = 'processing_events'
    
    event_id = db.Column(db.Integer, primary_key=True)
    batch_id = db.Column(db.Integer, db.ForeignKey('batches.batch_id'), nullable=False)
    unit_id = db.Column(db.Integer, db.ForeignKey('processing_units.unit_id'), nullable=False)
    event_type = db.Column(db.Enum('WASHING', 'CLEANING', 'SORTING', 'DRYING', 'GRINDING', 
                                  'PACKING', 'SPLIT', 'MERGE'), nullable=False)
    input_qty_kg = db.Column(Numeric(12, 3), nullable=False)
    output_qty_kg = db.Column(Numeric(12, 3), nullable=False)
    event_time = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    performed_by = db.Column(db.Integer, db.ForeignKey('users.user_id'), nullable=False)
    notes = db.Column(db.String(255))

class Inspection(db.Model):
    __tablename__ = 'inspections'
    
    inspection_id = db.Column(db.Integer, primary_key=True)
    batch_id = db.Column(db.Integer, db.ForeignKey('batches.batch_id'), nullable=False)
    inspector_id = db.Column(db.Integer, db.ForeignKey('users.user_id'), nullable=False)
    inspected_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    test_type = db.Column(db.String(80), nullable=False, default='GENERAL')
    result = db.Column(db.Enum('PASS', 'FAIL'), nullable=False)
    remarks = db.Column(db.String(500))
    
    parameters = db.relationship('InspectionParameter', backref='inspection', lazy=True, cascade='all, delete-orphan')

class InspectionParameter(db.Model):
    __tablename__ = 'inspection_parameters'
    
    parameter_id = db.Column(db.Integer, primary_key=True)
    inspection_id = db.Column(db.Integer, db.ForeignKey('inspections.inspection_id'), nullable=False)
    parameter_name = db.Column(db.String(80), nullable=False)
    measured_value = db.Column(Numeric(12, 4), nullable=False)
    limit_value = db.Column(Numeric(12, 4), nullable=False)
    limit_type = db.Column(db.Enum('MAX', 'MIN'), nullable=False, default='MAX')
    unit = db.Column(db.String(20), nullable=False)

class Shipment(db.Model):
    __tablename__ = 'shipments'
    
    shipment_id = db.Column(db.Integer, primary_key=True)
    batch_id = db.Column(db.Integer, db.ForeignKey('batches.batch_id'), nullable=False)
    retailer_id = db.Column(db.Integer, db.ForeignKey('users.user_id'), nullable=False)
    quantity_kg = db.Column(Numeric(12, 3), nullable=False)
    shipped_date = db.Column(db.Date, nullable=False)
    expected_delivery = db.Column(db.Date)
    status = db.Column(db.Enum('PENDING', 'IN_TRANSIT', 'DELIVERED', 'CANCELLED', 'RETURNED'), 
                       nullable=False, default='PENDING')
    confirmed_at = db.Column(db.DateTime)
    created_by = db.Column(db.Integer, db.ForeignKey('users.user_id'), nullable=False)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

class Recall(db.Model):
    __tablename__ = 'recalls'
    
    recall_id = db.Column(db.Integer, primary_key=True)
    recall_code = db.Column(db.String(30), nullable=False, unique=True)
    batch_id = db.Column(db.Integer, db.ForeignKey('batches.batch_id'), nullable=False)
    issued_by = db.Column(db.Integer, db.ForeignKey('users.user_id'), nullable=False)
    severity = db.Column(db.Enum('CLASS_I', 'CLASS_II', 'CLASS_III'), nullable=False)
    reason = db.Column(db.String(500), nullable=False)
    status = db.Column(db.Enum('OPEN', 'CLOSED'), nullable=False, default='OPEN')
    issued_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    closed_at = db.Column(db.DateTime)

class AuditLog(db.Model):
    __tablename__ = 'audit_log'
    
    log_id = db.Column(db.BigInteger, primary_key=True)
    table_name = db.Column(db.String(64), nullable=False)
    record_id = db.Column(db.BigInteger)
    action = db.Column(db.Enum('INSERT', 'UPDATE', 'DELETE', 'QUARANTINE', 'CANCEL_SHIPMENT', 
                              'RECALL', 'LOGIN', 'OTHER'), nullable=False)
    details = db.Column(db.JSON)
    performed_by = db.Column(db.Integer, db.ForeignKey('users.user_id'))
    performed_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
