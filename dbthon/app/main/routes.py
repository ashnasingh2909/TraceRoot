from decimal import Decimal
from datetime import date, timedelta

from flask import render_template, redirect, url_for, flash, request, jsonify
from flask_login import login_required, current_user
from sqlalchemy import or_, text
from app.main import bp
from app.models import *
from app.auth.decorators import *
from app import db

INSPECTION_TEST_TYPES = (
    'Visual examination',
    'Moisture content',
    'Foreign matter screening',
    'Pesticide residue screening',
    'Microbiological safety',
    'Packaging and labelling',
    'Temperature check',
    'Other approved test',
)


def _split_batch_transaction(parent_batch, children_data, user_id, processing_unit_id):
    if not children_data:
        raise ValueError('Please add at least one child batch')

    total_requested = Decimal('0')
    for idx, child in enumerate(children_data, start=1):
        qty = Decimal(str(child['qty']))
        if qty <= 0:
            raise ValueError(f'Child {idx} quantity must be greater than 0')
        total_requested += qty

    if total_requested > Decimal(str(parent_batch.quantity_kg)):
        raise ValueError('Insufficient quantity in parent batch - split rolled back')

    if parent_batch.processing_unit_id is None:
        parent_batch.processing_unit_id = processing_unit_id
    elif parent_batch.processing_unit_id != processing_unit_id:
        raise ValueError('This batch belongs to a different processing unit')

    created_children = []
    parent_code = parent_batch.batch_code
    next_suffix = 1
    while True:
        candidate = f'{parent_code}-S{next_suffix}'
        if not Batch.query.filter_by(batch_code=candidate).first():
            break
        next_suffix += 1

    for idx, child in enumerate(children_data, start=1):
        child_qty = Decimal(str(child['qty']))
        retailer_id = child.get('retailer_id')

        if retailer_id is not None:
            retailer = User.query.filter_by(user_id=int(retailer_id), is_active=True).first()
            if not retailer or not retailer.is_retailer():
                raise ValueError('retailer_id is not an active RETAILER user')

        suffix = next_suffix + idx - 1
        child_code = f'{parent_code}-S{suffix}'
        while Batch.query.filter_by(batch_code=child_code).first():
            suffix += 1
            child_code = f'{parent_code}-S{suffix}'

        child_batch = Batch(
            batch_code=child_code,
            product_id=parent_batch.product_id,
            batch_type='DERIVED',
            farm_id=None,
            processing_unit_id=parent_batch.processing_unit_id,
            initial_quantity_kg=child_qty,
            quantity_kg=Decimal('0') if retailer_id is not None else child_qty,
            harvest_date=parent_batch.harvest_date,
            expiry_date=parent_batch.expiry_date,
            status='ACTIVE',
            stage='SHIPPED' if retailer_id is not None else 'PACKED',
            created_by=user_id,
        )
        db.session.add(child_batch)
        db.session.flush()

        db.session.add(BatchLineage(
            parent_batch_id=parent_batch.batch_id,
            child_batch_id=child_batch.batch_id,
            quantity_used_kg=child_qty,
            relation_type='SPLIT',
        ))

        if retailer_id is not None:
            db.session.add(Shipment(
                batch_id=child_batch.batch_id,
                retailer_id=int(retailer_id),
                quantity_kg=child_qty,
                shipped_date=date.today(),
                expected_delivery=date.today() + timedelta(days=2),
                status='PENDING',
                created_by=user_id,
            ))

        created_children.append({
            'batch_id': child_batch.batch_id,
            'batch_code': child_batch.batch_code,
            'quantity_used_kg': child_qty,
            'retailer_id': int(retailer_id) if retailer_id is not None else None,
        })

    parent_batch.quantity_kg = Decimal(str(parent_batch.quantity_kg)) - total_requested
    if parent_batch.quantity_kg <= 0:
        parent_batch.status = 'CONSUMED'
        parent_batch.quantity_kg = Decimal('0')

    db.session.add(ProcessingEvent(
        batch_id=parent_batch.batch_id,
        unit_id=parent_batch.processing_unit_id,
        event_type='SPLIT',
        input_qty_kg=total_requested,
        output_qty_kg=total_requested,
        performed_by=user_id,
        notes=f'Split into {len(children_data)} child batches',
    ))

    db.session.commit()

    return {'created_children': len(created_children), 'children': created_children}


def _origin_farm_ids(batch_id):
    farm_ids = set()
    visited_batch_ids = set()
    pending_batch_ids = [batch_id]

    while pending_batch_ids:
        current_id = pending_batch_ids.pop()
        if current_id in visited_batch_ids:
            continue
        visited_batch_ids.add(current_id)

        batch = db.session.get(Batch, current_id)
        if batch is None:
            continue
        if batch.farm_id is not None:
            farm_ids.add(batch.farm_id)

        parent_ids = db.session.query(BatchLineage.parent_batch_id).filter(
            BatchLineage.child_batch_id == current_id
        ).all()
        pending_batch_ids.extend(parent_id for (parent_id,) in parent_ids)

    return farm_ids


def _batch_lineage_family_ids(batch_id):
    family_ids = set()
    pending_batch_ids = [batch_id]

    while pending_batch_ids:
        current_id = pending_batch_ids.pop()
        if current_id in family_ids:
            continue
        family_ids.add(current_id)

        parent_ids = db.session.query(BatchLineage.parent_batch_id).filter(
            BatchLineage.child_batch_id == current_id
        ).all()
        child_ids = db.session.query(BatchLineage.child_batch_id).filter(
            BatchLineage.parent_batch_id == current_id
        ).all()
        pending_batch_ids.extend(related_id for (related_id,) in parent_ids)
        pending_batch_ids.extend(related_id for (related_id,) in child_ids)

    return family_ids


def apply_recall_to_batch_family(batch_id, recall_id, reason, user_id):
    family_ids = _batch_lineage_family_ids(batch_id)
    family_batches = Batch.query.filter(Batch.batch_id.in_(family_ids)).all()
    affected_batches = []

    for family_batch in family_batches:
        if family_batch.status != 'RECALLED':
            previous_status = family_batch.status
            family_batch.status = 'RECALLED'
            affected_batches.append(family_batch)
            _add_audit_log(
                table_name='batches',
                record_id=family_batch.batch_id,
                action='RECALL',
                details={
                    'recall_id': recall_id,
                    'recall_batch_id': batch_id,
                    'previous_status': previous_status,
                    'reason': reason,
                },
                performed_by=user_id,
            )

    family_shipments = Shipment.query.filter(
        Shipment.batch_id.in_(family_ids),
        Shipment.status.in_(['PENDING', 'IN_TRANSIT']),
    ).all()
    for shipment in family_shipments:
        shipment.status = 'CANCELLED'

    if family_shipments:
        _add_audit_log(
            table_name='shipments',
            record_id=batch_id,
            action='CANCEL_SHIPMENT',
            details={
                'recall_id': recall_id,
                'cancelled_count': len(family_shipments),
                'batch_ids': sorted(family_ids),
            },
            performed_by=user_id,
        )

    return len(affected_batches), len(family_shipments)


def _add_audit_log(**values):
    if db.engine.url.get_backend_name() == 'sqlite':
        latest_id = db.session.query(db.func.max(AuditLog.log_id)).scalar() or 0
        values['log_id'] = latest_id + 1
    audit_entry = AuditLog(**values)
    db.session.add(audit_entry)
    db.session.flush()
    return audit_entry

@bp.route('/')
def index():
    if current_user.is_authenticated:
        return redirect(url_for('main.dashboard'))
    return render_template('index.html')

@bp.route('/dashboard')
@login_required
def dashboard():
    """Role-based dashboard"""
    if current_user.is_admin():
        users = User.query.all()
        farms = Farm.query.all()
        batches = Batch.query.all()
        recalls = Recall.query.all()
        return render_template('dashboard/admin.html', users=users, farms=farms, batches=batches, recalls=recalls)
    elif current_user.is_farmer():
        farms = Farm.query.filter_by(owner_id=current_user.user_id).all()
        farm_ids = [f.farm_id for f in farms]
        batches = Batch.query.filter(Batch.farm_id.in_(farm_ids)).all()
        shipped_count = sum(1 for b in batches if b.stage == 'SHIPPED')
        return render_template('dashboard/farmer.html', farms=farms, batches=batches, shipped_count=shipped_count)
    elif current_user.is_processor():
        unit_ids = [u.unit_id for u in current_user.managed_units]
        batches = Batch.query.filter(or_(
            Batch.processing_unit_id.in_(unit_ids),
            Batch.processing_unit_id.is_(None),
        )).order_by(Batch.created_at.desc()).all()
        events = ProcessingEvent.query.filter_by(performed_by=current_user.user_id).all()
        splits = [e for e in events if e.event_type == 'SPLIT']
        merges = [e for e in events if e.event_type == 'MERGE']
        return render_template('dashboard/processor.html', batches=batches, events=events, splits=splits, merges=merges)
    elif current_user.is_inspector():
        inspections = Inspection.query.filter_by(inspector_id=current_user.user_id).all()
        pending = Batch.query.filter(Batch.status.in_(['ACTIVE'])).all()
        passed = [i for i in inspections if i.result == 'PASS']
        failed = [i for i in inspections if i.result == 'FAIL']
        quarantined = Batch.query.filter_by(status='QUARANTINED').all()
        return render_template('dashboard/inspector.html', pending=pending, passed=passed, failed=failed, quarantined=quarantined, inspections=inspections)
    elif current_user.is_retailer():
        shipments = Shipment.query.filter_by(retailer_id=current_user.user_id).all()
        delivered = [s for s in shipments if s.status == 'DELIVERED']
        in_transit = [s for s in shipments if s.status == 'IN_TRANSIT']
        total_kg = sum(s.quantity_kg for s in shipments if s.status == 'DELIVERED')
        approved_batches = Batch.query.join(Inspection).filter(
            Inspection.result == 'PASS',
            Batch.status == 'ACTIVE',
            Batch.quantity_kg > 0,
        ).distinct().order_by(Batch.created_at.desc()).all()
        return render_template(
            'dashboard/retailer.html',
            shipments=shipments,
            delivered=delivered,
            in_transit=in_transit,
            total_kg=total_kg,
            approved_batches=approved_batches,
        )
    elif current_user.is_food_safety_officer():
        total_batches = Batch.query.count()
        total_inspections = Inspection.query.count()
        open_recalls = Recall.query.filter_by(status='OPEN').all()
        quarantined = Batch.query.filter_by(status='QUARANTINED').all()
        quarantined_farms = Farm.query.filter_by(status='QUARANTINED').order_by(Farm.farm_name).all()
        return render_template('dashboard/fso.html', total_batches=total_batches, total_inspections=total_inspections, open_recalls=open_recalls, quarantined=quarantined, quarantined_farms=quarantined_farms)
    return render_template('dashboard/index.html')

# ==================== ADMIN ROUTES ====================

@bp.route('/admin/users')
@login_required
@admin_required
def admin_users():
    users = User.query.order_by(User.created_at.desc()).all()
    return render_template('admin/users.html', users=users)

@bp.route('/admin/users/<int:user_id>/toggle', methods=['POST'])
@login_required
@admin_required
def toggle_user(user_id):
    user = User.query.get_or_404(user_id)
    user.is_active = not user.is_active
    db.session.commit()
    status = 'activated' if user.is_active else 'deactivated'
    flash(f'User {user.username} has been {status}', 'success')
    return redirect(url_for('main.admin_users'))

# ==================== FARMER ROUTES ====================

@bp.route('/farmer/farms')
@login_required
@farmer_required
def farmer_farms():
    farms = Farm.query.filter_by(owner_id=current_user.user_id).all()
    return render_template('farmer/farms.html', farms=farms)

@bp.route('/farmer/batches')
@login_required
@farmer_required
def farmer_batches():
    batches = Batch.query.filter(
        Batch.farm_id.in_([f.farm_id for f in current_user.owned_farms])
    ).order_by(Batch.created_at.desc()).all()
    return render_template('farmer/batches.html', batches=batches)

@bp.route('/farmer/batch/create', methods=['GET', 'POST'])
@login_required
@farmer_required
def create_batch():
    if request.method == 'POST':
        try:
            batch_code = request.form.get('batch_code')
            product_id = request.form.get('product_id')
            farm_id = request.form.get('farm_id')
            quantity_kg = float(request.form.get('quantity_kg'))
            harvest_date = request.form.get('harvest_date')

            farm = Farm.query.filter_by(
                farm_id=farm_id,
                owner_id=current_user.user_id,
            ).first()
            if farm is None:
                raise ValueError('Select one of your registered farms')
            if farm.status != 'ACTIVE':
                raise ValueError('This farm is quarantined and cannot create new batches')
            
            product = Product.query.get(product_id)
            from datetime import datetime, timedelta
            expiry_date = datetime.strptime(harvest_date, '%Y-%m-%d') + timedelta(days=product.shelf_life_days)
            
            batch = Batch(
                batch_code=batch_code,
                product_id=product_id,
                batch_type='HARVEST',
                farm_id=farm.farm_id,
                initial_quantity_kg=quantity_kg,
                quantity_kg=quantity_kg,
                harvest_date=datetime.strptime(harvest_date, '%Y-%m-%d').date(),
                expiry_date=expiry_date.date(),
                created_by=current_user.user_id
            )
            db.session.add(batch)
            db.session.commit()
            
            flash(f'Batch {batch_code} created successfully', 'success')
            return redirect(url_for('main.farmer_batches'))
        except Exception as e:
            db.session.rollback()
            flash(f'Error creating batch: {str(e)}', 'danger')
    
    farms = Farm.query.filter_by(owner_id=current_user.user_id, status='ACTIVE').all()
    products = Product.query.all()
    return render_template('farmer/create_batch.html', farms=farms, products=products)

# ==================== PROCESSOR ROUTES ====================

@bp.route('/processor/batches')
@login_required
@processor_required
def processor_batches():
    unit_ids = [u.unit_id for u in current_user.managed_units]
    batches = Batch.query.filter(or_(
        Batch.processing_unit_id.in_(unit_ids),
        Batch.processing_unit_id.is_(None),
    )).order_by(Batch.created_at.desc()).all()
    return render_template('processor/batches.html', batches=batches)

@bp.route('/processor/split/<int:batch_id>', methods=['GET', 'POST'])
@login_required
@processor_required
def split_batch(batch_id):
    batch = Batch.query.get_or_404(batch_id)
    unit_ids = [unit.unit_id for unit in current_user.managed_units]

    if not unit_ids:
        flash('Your account is not assigned to a processing unit', 'danger')
        return redirect(url_for('main.processor_batches'))

    if batch.processing_unit_id is not None and batch.processing_unit_id not in unit_ids:
        flash('This batch belongs to a different processing unit', 'danger')
        return redirect(url_for('main.processor_batches'))
    
    if request.method == 'POST':
        try:
            children_data = []
            for i in range(1, 4):  # Support up to 3 splits
                qty = request.form.get(f'child_{i}_qty')
                retailer_id = request.form.get(f'child_{i}_retailer')
                if qty and float(qty) > 0:
                    child = {'qty': float(qty)}
                    if retailer_id:
                        child['retailer_id'] = int(retailer_id)
                    children_data.append(child)
            
            if not children_data:
                flash('Please add at least one child batch', 'warning')
                return redirect(url_for('main.split_batch', batch_id=batch_id))

            if 'sqlite' in db.engine.url.drivername:
                _split_batch_transaction(batch, children_data, current_user.user_id, unit_ids[0])
            else:
                if batch.processing_unit_id is None:
                    batch.processing_unit_id = unit_ids[0]
                    db.session.commit()
                import json
                result = db.session.execute(
                    text('CALL sp_split_batch(:parent_id, :user_id, :children)'),
                    {'parent_id': batch_id, 'user_id': current_user.user_id, 'children': json.dumps(children_data)}
                )
                db.session.commit()
            
            flash('Batch split successfully', 'success')
            return redirect(url_for('main.processor_batches'))
        except Exception as e:
            db.session.rollback()
            flash(f'Error splitting batch: {str(e)}', 'danger')
    
    retailers = User.query.join(User.role).filter(Role.role_name == 'RETAILER', User.is_active == True).all()
    return render_template('processor/split_batch.html', batch=batch, retailers=retailers)

@bp.route('/processor/processing-events')
@login_required
@processor_required
def processing_events():
    events = ProcessingEvent.query.filter_by(performed_by=current_user.user_id).order_by(ProcessingEvent.event_time.desc()).all()
    return render_template('processor/events.html', events=events)

# ==================== INSPECTOR ROUTES ====================

@bp.route('/inspector/batches')
@login_required
@inspector_required
def inspector_batches():
    batches = Batch.query.filter(Batch.status.in_(['ACTIVE', 'QUARANTINED'])).order_by(Batch.created_at.desc()).all()
    return render_template('inspector/batches.html', batches=batches)

@bp.route('/inspector/inspection/create/<int:batch_id>', methods=['GET', 'POST'])
@login_required
@inspector_required
def create_inspection(batch_id):
    batch = Batch.query.get_or_404(batch_id)
    
    if request.method == 'POST':
        try:
            result = request.form.get('result')
            test_type = request.form.get('test_type')
            remarks = request.form.get('remarks')

            if test_type not in INSPECTION_TEST_TYPES:
                raise ValueError('Select a valid inspection test')

            if result not in ('PASS', 'FAIL'):
                raise ValueError('Select a valid inspection result')

            if result == 'FAIL':
                origin_farms = Farm.query.filter(Farm.farm_id.in_(_origin_farm_ids(batch_id))).all()
                previous_batch_status = batch.status
                batch.status = 'QUARANTINED'
                for farm in origin_farms:
                    farm.status = 'QUARANTINED'

                pending_shipments = Shipment.query.filter_by(
                    batch_id=batch_id,
                    status='PENDING',
                ).all()
                for shipment in pending_shipments:
                    shipment.status = 'CANCELLED'

                db.session.flush()

                _add_audit_log(
                    table_name='batches',
                    record_id=batch_id,
                    action='QUARANTINE',
                    details={
                        'reason': 'Inspection failed',
                        'previous_status': previous_batch_status,
                        'inspection_test': test_type,
                        'cancelled_pending_shipments': len(pending_shipments),
                    },
                    performed_by=current_user.user_id,
                )
                if pending_shipments:
                    _add_audit_log(
                        table_name='shipments',
                        record_id=batch_id,
                        action='CANCEL_SHIPMENT',
                        details={
                            'cancelled_count': len(pending_shipments),
                            'reason': 'Inspection failed',
                        },
                        performed_by=current_user.user_id,
                    )
                for farm in origin_farms:
                    _add_audit_log(
                        table_name='farms',
                        record_id=farm.farm_id,
                        action='QUARANTINE',
                        details={
                            'reason': 'Origin batch failed inspection',
                            'batch_id': batch_id,
                            'inspection_test': test_type,
                        },
                        performed_by=current_user.user_id,
                    )
            
            inspection = Inspection(
                batch_id=batch_id,
                inspector_id=current_user.user_id,
                test_type=test_type,
                result=result,
                remarks=remarks
            )
            db.session.add(inspection)
            
            db.session.commit()
            flash(f'Inspection recorded successfully', 'success')
            return redirect(url_for('main.inspector_batches'))
        except Exception as e:
            db.session.rollback()
            flash(f'Error creating inspection: {str(e)}', 'danger')
    
    return render_template(
        'inspector/create_inspection.html',
        batch=batch,
        test_types=INSPECTION_TEST_TYPES,
    )

# ==================== RETAILER ROUTES ====================

@bp.route('/retailer/shipments')
@login_required
@retailer_required
def retailer_shipments():
    shipments = Shipment.query.filter_by(retailer_id=current_user.user_id).order_by(Shipment.shipped_date.desc()).all()
    return render_template('retailer/shipments.html', shipments=shipments)

@bp.route('/retailer/shipment/<int:shipment_id>/confirm', methods=['POST'])
@login_required
@retailer_required
def confirm_shipment(shipment_id):
    shipment = Shipment.query.get_or_404(shipment_id)
    if shipment.retailer_id != current_user.user_id:
        flash('Unauthorized', 'danger')
        return redirect(url_for('main.retailer_shipments'))
    
    shipment.status = 'DELIVERED'
    from datetime import datetime
    shipment.confirmed_at = datetime.utcnow()
    db.session.commit()
    
    flash('Shipment confirmed as delivered', 'success')
    return redirect(url_for('main.retailer_shipments'))

@bp.route('/retailer/batch/<int:batch_id>')
@login_required
@retailer_required
def view_batch_history(batch_id):
    batch = Batch.query.get_or_404(batch_id)
    return render_template('retailer/batch_history.html', batch=batch)

# ==================== FOOD SAFETY OFFICER ROUTES ====================

@bp.route('/fso/recalls')
@login_required
@fso_required
def fso_recalls():
    recalls = Recall.query.order_by(Recall.issued_at.desc()).all()
    return render_template('fso/recalls.html', recalls=recalls)

@bp.route('/fso/recall/create', methods=['GET', 'POST'])
@login_required
@fso_required
def create_recall():
    if request.method == 'POST':
        try:
            batch_id = request.form.get('batch_id', type=int)
            severity = request.form.get('severity')
            reason = (request.form.get('reason') or '').strip()

            if severity not in ('CLASS_I', 'CLASS_II', 'CLASS_III'):
                raise ValueError('Select a valid recall severity')
            if not reason:
                raise ValueError('Enter a reason for the recall')

            batch = Batch.query.get_or_404(batch_id)
            
            recall = Recall(
                recall_code=f'REC-{batch.batch_code}',
                batch_id=batch.batch_id,
                issued_by=current_user.user_id,
                severity=severity,
                reason=reason
            )
            db.session.add(recall)
            db.session.flush()

            affected_count, cancelled_count = apply_recall_to_batch_family(
                batch.batch_id,
                recall.recall_id,
                reason,
                current_user.user_id,
            )

            db.session.commit()
            
            flash(
                f'Recall {recall.recall_code} issued for {affected_count} related batches; '
                f'{cancelled_count} active shipments cancelled',
                'success',
            )
            return redirect(url_for('main.fso_recalls'))
        except Exception as e:
            db.session.rollback()
            flash(f'Error creating recall: {str(e)}', 'danger')
    
    batches = Batch.query.filter(Batch.status.in_(['ACTIVE', 'QUARANTINED'])).all()
    return render_template('fso/create_recall.html', batches=batches)

@bp.route('/fso/recall/<int:recall_id>/close', methods=['POST'])
@login_required
@fso_required
def close_recall(recall_id):
    recall = Recall.query.get_or_404(recall_id)
    recall.status = 'CLOSED'
    from datetime import datetime
    recall.closed_at = datetime.utcnow()
    db.session.commit()
    
    flash(f'Recall {recall.recall_code} closed', 'success')
    return redirect(url_for('main.fso_recalls'))


@bp.route('/fso/farm/<int:farm_id>/release', methods=['POST'])
@login_required
@fso_required
def release_farm_quarantine(farm_id):
    farm = Farm.query.get_or_404(farm_id)
    if farm.status != 'QUARANTINED':
        flash('This farm is not under quarantine', 'warning')
        return redirect(url_for('main.dashboard'))

    farm.status = 'ACTIVE'
    _add_audit_log(
        table_name='farms',
        record_id=farm.farm_id,
        action='UPDATE',
        details={'status': 'ACTIVE', 'reason': 'Released by food safety officer'},
        performed_by=current_user.user_id,
    )
    db.session.commit()

    flash(f'Farm {farm.farm_name} released from quarantine', 'success')
    return redirect(url_for('main.dashboard'))

# ==================== COMMON ROUTES ====================

@bp.route('/batches')
@login_required
def list_batches():
    page = request.args.get('page', 1, type=int)
    search = request.args.get('search', '')
    status_filter = request.args.get('status', '')
    
    query = Batch.query
    
    if search:
        query = query.filter(Batch.batch_code.like(f'%{search}%'))
    
    if status_filter:
        query = query.filter(Batch.status == status_filter)
    
    batches = query.order_by(Batch.created_at.desc()).paginate(page=page, per_page=20)
    return render_template('batches/list.html', batches=batches, search=search, status_filter=status_filter)

@bp.route('/batch/<int:batch_id>')
@login_required
def view_batch(batch_id):
    batch = Batch.query.get_or_404(batch_id)
    return render_template('batches/detail.html', batch=batch)

@bp.route('/recall-simulation', methods=['GET', 'POST'])
@login_required
def recall_simulation():
    """Recall trace simulation page"""
    if request.method == 'POST':
        batch_id = request.form.get('batch_id')
        try:
            result = db.session.execute(text('CALL sp_trace_recall(:batch_id)'), {'batch_id': batch_id})
            
            # Get all result sets
            result_sets = []
            while True:
                try:
                    rows = result.fetchall()
                    if rows:
                        columns = result.keys()
                        result_sets.append([dict(zip(columns, row)) for row in rows])
                    if not result.nextset():
                        break
                except:
                    break
            
            return render_template('recall/simulation.html', batch_id=batch_id, result_sets=result_sets)
        except Exception as e:
            flash(f'Error tracing recall: {str(e)}', 'danger')
    
    return render_template('recall/simulation.html')

@bp.route('/reports')
@login_required
def reports():
    """Analytics and reports"""
    return render_template('reports/index.html')
