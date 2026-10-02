import os
from functools import lru_cache
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker


@lru_cache
def engine():
    url = os.environ.get('DATABASE_URL', '')
    if url.startswith('postgres://'):
        url = url.replace('postgres://', 'postgresql://', 1)
    if url.startswith('postgresql://'):
        url = url.replace('postgresql://', 'postgresql+psycopg://', 1)
    if not url.startswith('postgresql+psycopg://'):
        raise RuntimeError('DATABASE_URL must point to PostgreSQL')
    return create_engine(url, pool_pre_ping=True, pool_size=5, max_overflow=5,
                         connect_args={'connect_timeout': 10, 'options': '-c statement_timeout=30000'})


def session():
    return sessionmaker(engine(), expire_on_commit=False)()
