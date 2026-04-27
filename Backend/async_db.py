# Backend/server/async_db.py
"""
Async Database Configuration for Production Performance

CRITICAL MIGRATION: This replaces the synchronous pymysql driver with
async aiomysql driver. This is THE key change that allows your server
to handle 100+ concurrent requests instead of just 8.

HOW IT WORKS:
- Old: db.query(Tourist).filter(...).first()  <- BLOCKS event loop
- New: await db.execute(select(Tourist).where(...))  <- NON-BLOCKING

MIGRATION STEPS:
1. Copy this file to server/async_db.py
2. Update imports in routers: from ..async_db import AsyncSessionLocal, get_async_db
3. Update route functions to use async queries (see examples below)
"""

import os
import logging
from typing import AsyncGenerator
from contextlib import asynccontextmanager

from sqlalchemy.ext.asyncio import AsyncSession, create_async_engine, async_sessionmaker
from sqlalchemy.orm import declarative_base
from sqlalchemy import text

logger = logging.getLogger(__name__)

# ============================================
# Async Engine Configuration
# ============================================

# Get database URL from environment
MYSQL_URI = os.getenv("MYSQL_URI", "mysql+aiomysql://root:root123@db:3306/dtid_db")

# Convert sync URL to async URL if needed
if "pymysql" in MYSQL_URI:
    ASYNC_MYSQL_URI = MYSQL_URI.replace("pymysql", "aiomysql")
elif "aiomysql" not in MYSQL_URI:
    # Add aiomysql driver if not specified
    ASYNC_MYSQL_URI = MYSQL_URI.replace("mysql://", "mysql+aiomysql://")
else:
    ASYNC_MYSQL_URI = MYSQL_URI

# PostgreSQL for geofencing
POSTGRES_URI = os.getenv("GEOFENCE_DATABASE_URL", "postgresql+asyncpg://postgres:postgres@postgres:5432/geofencing_db")

# Convert sync URL to async if needed
if "asyncpg" not in POSTGRES_URI:
    ASYNC_POSTGRES_URI = POSTGRES_URI.replace("postgresql://", "postgresql+asyncpg://")
else:
    ASYNC_POSTGRES_URI = POSTGRES_URI

# Create async engines with connection pooling
mysql_async_engine = create_async_engine(
    ASYNC_MYSQL_URI,
    pool_size=20,           # Number of connections to keep open
    max_overflow=30,        # Additional connections when pool is full
    pool_timeout=30,        # Timeout waiting for connection
    pool_recycle=3600,      # Recycle connections after 1 hour
    pool_pre_ping=True,     # Verify connection before using
    echo=False,             # Set to True for SQL debugging
)

postgres_async_engine = create_async_engine(
    ASYNC_POSTGRES_URI,
    pool_size=10,
    max_overflow=20,
    pool_timeout=30,
    pool_recycle=3600,
    pool_pre_ping=True,
    echo=False,
)

# Create async session factories
AsyncSessionLocal = async_sessionmaker(
    bind=mysql_async_engine,
    class_=AsyncSession,
    expire_on_commit=False,
    autocommit=False,
    autoflush=False,
)

AsyncGeofenceSessionLocal = async_sessionmaker(
    bind=postgres_async_engine,
    class_=AsyncSession,
    expire_on_commit=False,
    autocommit=False,
    autoflush=False,
)

# Base class for models (same as before)
Base = declarative_base()

# ============================================
# Dependency Injection for FastAPI
# ============================================

async def get_async_db() -> AsyncGenerator[AsyncSession, None]:
    """
    FastAPI dependency for async database sessions.
    
    Usage in routers:
    ```python
    from ..async_db import get_async_db
    
    @router.get("/example")
    async def example_route(db: AsyncSession = Depends(get_async_db)):
        result = await db.execute(select(Tourist).where(Tourist.id == "DTID-XXX"))
        tourist = result.scalars().first()
        return {"name": tourist.name}
    ```
    """
    async with AsyncSessionLocal() as session:
        try:
            yield session
            await session.commit()
        except Exception as e:
            await session.rollback()
            logger.error(f"Database error: {e}")
            raise
        finally:
            await session.close()


async def get_async_geofence_db() -> AsyncGenerator[AsyncSession, None]:
    """Dependency for geofencing database (PostgreSQL)"""
    async with AsyncGeofenceSessionLocal() as session:
        try:
            yield session
            await session.commit()
        except Exception as e:
            await session.rollback()
            logger.error(f"Geofence DB error: {e}")
            raise
        finally:
            await session.close()


# ============================================
# Context Manager for Manual Sessions
# ============================================

@asynccontextmanager
async def get_db_session():
    """
    Context manager for database sessions outside of FastAPI routes.
    
    Usage in Celery tasks:
    ```python
    async with get_db_session() as db:
        result = await db.execute(select(Tourist))
        tourists = result.scalars().all()
    ```
    """
    async with AsyncSessionLocal() as session:
        try:
            yield session
            await session.commit()
        except Exception as e:
            await session.rollback()
            logger.error(f"Database session error: {e}")
            raise


# ============================================
# Health Check
# ============================================

async def check_db_connection() -> bool:
    """Check if database is accessible"""
    try:
        async with AsyncSessionLocal() as session:
            await session.execute(text("SELECT 1"))
            return True
    except Exception as e:
        logger.error(f"Database health check failed: {e}")
        return False


# ============================================
# Query Examples (For Migration Reference)
# ============================================

"""
MIGRATION EXAMPLES - How to convert your existing queries:

===============================================
EXAMPLE 1: Simple Query
===============================================
OLD (Blocking):
    tourist = db.query(Tourist).filter(Tourist.id == token_id).first()

NEW (Async):
    from sqlalchemy import select
    result = await db.execute(select(Tourist).where(Tourist.id == token_id))
    tourist = result.scalars().first()

===============================================
EXAMPLE 2: Multiple Filters
===============================================
OLD:
    alerts = db.query(Alert).filter(
        Alert.tourist_id == user_id,
        Alert.status == AlertStatus.ACTIVE
    ).all()

NEW:
    from sqlalchemy import select, and_
    result = await db.execute(
        select(Alert).where(
            and_(
                Alert.tourist_id == user_id,
                Alert.status == AlertStatus.ACTIVE
            )
        )
    )
    alerts = result.scalars().all()

===============================================
EXAMPLE 3: Insert
===============================================
OLD:
    new_tourist = Tourist(id=dtid, mobile_hash=mobile_hash, ...)
    db.add(new_tourist)
    db.commit()

NEW:
    new_tourist = Tourist(id=dtid, mobile_hash=mobile_hash, ...)
    db.add(new_tourist)
    await db.commit()

===============================================
EXAMPLE 4: Update
===============================================
OLD:
    tourist.status = TouristStatus.ACTIVE
    db.commit()

NEW:
    tourist.status = TouristStatus.ACTIVE
    await db.commit()

===============================================
EXAMPLE 5: Raw SQL (unchanged mostly)
===============================================
OLD:
    result = db.execute(text("SELECT * FROM tourists WHERE id = :id"), {"id": id})

NEW:
    result = await db.execute(text("SELECT * FROM tourists WHERE id = :id"), {"id": id})

===============================================
EXAMPLE 6: Join Query
===============================================
OLD:
    results = db.query(Alert, Tourist).join(Tourist).filter(...).all()

NEW:
    from sqlalchemy import select
    stmt = select(Alert, Tourist).join(Tourist).where(...)
    result = await db.execute(stmt)
    results = result.all()

===============================================
EXAMPLE 7: Count
===============================================
OLD:
    count = db.query(Alert).filter(Alert.status == "ACTIVE").count()

NEW:
    from sqlalchemy import select, func
    result = await db.execute(
        select(func.count()).select_from(Alert).where(Alert.status == "ACTIVE")
    )
    count = result.scalar()
"""

# ============================================
# Startup/Shutdown Events
# ============================================

async def init_async_db():
    """Initialize database connections on startup"""
    logger.info("Initializing async database connections...")
    
    # Test MySQL connection
    try:
        async with mysql_async_engine.connect() as conn:
            await conn.execute(text("SELECT 1"))
        logger.info("✅ MySQL async connection successful")
    except Exception as e:
        logger.error(f"❌ MySQL async connection failed: {e}")
        raise
    
    # Test PostgreSQL connection
    try:
        async with postgres_async_engine.connect() as conn:
            await conn.execute(text("SELECT 1"))
        logger.info("✅ PostgreSQL async connection successful")
    except Exception as e:
        logger.warning(f"⚠️ PostgreSQL connection failed (geofencing may not work): {e}")


async def close_async_db():
    """Close database connections on shutdown"""
    logger.info("Closing async database connections...")
    await mysql_async_engine.dispose()
    await postgres_async_engine.dispose()
    logger.info("✅ Database connections closed")
