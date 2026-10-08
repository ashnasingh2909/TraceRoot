from flask import jsonify, request
from sqlalchemy import text
from app.api import bp
from app.models import *
from app import db

@bp.route('/batch/<int:batch_id>/risk-score')
def batch_risk_score(batch_id):
    """Get risk score for a batch"""
    try:
        result = db.session.execute(
            text('SELECT fn_batch_risk_score(:batch_id) AS score'),
            {'batch_id': batch_id}
        ).fetchone()
        return jsonify({'success': True, 'score': result[0] if result else None})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

@bp.route('/batch/<int:batch_id>/trace')
def batch_trace(batch_id):
    """Get batch trace summary"""
    try:
        result = db.session.execute(
            text('SELECT * FROM v_batch_trace_summary WHERE batch_id = :batch_id'),
            {'batch_id': batch_id}
        ).fetchone()
        if result:
            columns = result.keys()
            return jsonify({'success': True, 'data': dict(zip(columns, result))})
        return jsonify({'success': False, 'error': 'Batch not found'}), 404
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

@bp.route('/stats/dashboard')
def dashboard_stats():
    """Get dashboard statistics"""
    try:
        stats = {
            'total_batches': db.session.query(Batch).count(),
            'active_batches': db.session.query(Batch).filter_by(status='ACTIVE').count(),
            'quarantined_batches': db.session.query(Batch).filter_by(status='QUARANTINED').count(),
            'recalled_batches': db.session.query(Batch).filter_by(status='RECALLED').count(),
            'total_shipments': db.session.query(Shipment).count(),
            'open_recalls': db.session.query(Recall).filter_by(status='OPEN').count(),
            'total_farms': db.session.query(Farm).count(),
            'total_inspections': db.session.query(Inspection).count(),
        }
        return jsonify({'success': True, 'stats': stats})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

@bp.route('/products')
def get_products():
    """Get all products"""
    products = Product.query.all()
    return jsonify({
        'success': True,
        'products': [{'id': p.product_id, 'name': p.product_name, 'category': p.category} for p in products]
    })

@bp.route('/farms')
def get_farms():
    """Get all farms"""
    farms = Farm.query.all()
    return jsonify({
        'success': True,
        'farms': [{'id': f.farm_id, 'code': f.farm_code, 'name': f.farm_name} for f in farms]
    })
