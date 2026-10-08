import os
from dotenv import load_dotenv

load_dotenv()


def _build_database_uri():
    database_url = os.environ.get('DATABASE_URL')
    if database_url:
        return database_url

    db_host = os.environ.get('DB_HOST')
    db_user = os.environ.get('DB_USER')
    db_name = os.environ.get('DB_NAME')

    if db_host and db_user and db_name:
        db_port = os.environ.get('DB_PORT') or '3306'
        db_password = os.environ.get('DB_PASSWORD') or ''
        try:
            import mysql.connector
            mysql.connector.connect(
                host=db_host,
                port=int(db_port),
                user=db_user,
                password=db_password,
                database=db_name,
                connection_timeout=2,
            ).close()
            return f'mysql+mysqlconnector://{db_user}:{db_password}@{db_host}:{db_port}/{db_name}'
        except Exception:
            pass

    base_dir = os.path.abspath(os.path.dirname(__file__))
    return f'sqlite:///{os.path.join(base_dir, "app.db")}'


class Config:
    SECRET_KEY = os.environ.get('SECRET_KEY') or 'dev-secret-key-change-in-production'

    # Database configuration
    DB_HOST = os.environ.get('DB_HOST')
    DB_PORT = os.environ.get('DB_PORT') or '3306'
    DB_USER = os.environ.get('DB_USER')
    DB_PASSWORD = os.environ.get('DB_PASSWORD') or ''
    DB_NAME = os.environ.get('DB_NAME')

    SQLALCHEMY_DATABASE_URI = _build_database_uri()
    SQLALCHEMY_TRACK_MODIFICATIONS = False
    SQLALCHEMY_ENGINE_OPTIONS = {}
    if 'mysql' in SQLALCHEMY_DATABASE_URI:
        SQLALCHEMY_ENGINE_OPTIONS.update({
            'pool_pre_ping': True,
            'pool_recycle': 3600,
        })
