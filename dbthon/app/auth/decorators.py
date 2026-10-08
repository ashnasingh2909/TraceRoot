from functools import wraps
from flask import flash, redirect, url_for
from flask_login import current_user

def role_required(*roles):
    """Decorator to require specific user roles"""
    def decorator(f):
        @wraps(f)
        def decorated_function(*args, **kwargs):
            if not current_user.is_authenticated:
                flash('Please log in to access this page', 'warning')
                return redirect(url_for('auth.login'))
            
            if not current_user.role or current_user.role.role_name not in roles:
                flash('You do not have permission to access this page', 'danger')
                return redirect(url_for('main.dashboard'))
            
            return f(*args, **kwargs)
        return decorated_function
    return decorator

def admin_required(f):
    """Decorator to require admin role"""
    return role_required('ADMIN')(f)

def farmer_required(f):
    """Decorator to require farmer role"""
    return role_required('FARMER')(f)

def processor_required(f):
    """Decorator to require processor role"""
    return role_required('PROCESSOR')(f)

def inspector_required(f):
    """Decorator to require inspector role"""
    return role_required('INSPECTOR')(f)

def retailer_required(f):
    """Decorator to require retailer role"""
    return role_required('RETAILER')(f)

def fso_required(f):
    """Decorator to require food safety officer role"""
    return role_required('FOOD_SAFETY_OFFICER')(f)
