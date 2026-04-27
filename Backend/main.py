# server/main.py
import sys
import os
import asyncio
import platform



# ✅ CRITICAL: Set event loop policy BEFORE any async operations
if platform.system() == 'Windows':
    # WindowsSelectorEventLoopPolicy supports subprocess
    asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())
    print("✅ Set Windows event loop policy to SelectorEventLoopPolicy")

# NOW import everything else
import logging
import time

from contextlib import asynccontextmanager
from fastapi import FastAPI, HTTPException, status, Depends, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
import uvicorn
from dotenv import load_dotenv
env_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), '.env')
load_dotenv(dotenv_path=env_path)
from fastapi import FastAPI, HTTPException
from pydantic import ValidationError
from tourist_safety_chatbot.api.routes import router as chatbot_router
# import the plain handler functions you just added
from tourist_safety_chatbot.api.routes import (
    http_exception_handler,
    validation_exception_handler
)
from .async_db import get_async_db
from sqlalchemy import select, and_
from sqlalchemy.ext.asyncio import AsyncSession
from contextlib import asynccontextmanager
from .utils import safety_calculator

# @asynccontextmanager
# async def get_db_session():
#     async with AsyncSession() as session:
#         yield session


# Load environment variables
# load_dotenv( 
#     # dotenv_path=".\.env"
#     dotenv_path=os.path.join(os.path.dirname(__file__), '.', '.env')
# )

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('dtid_server.log'),
        logging.StreamHandler()
    ]
)

logger = logging.getLogger(__name__)
ipfs_process = None
ganache_process = None

# Import our modules
from .db import init_database, check_database_connection
from .blockchain import init_blockchain
from .routers import issuance, access, auth, groups, alerts, tracking
from .routers.auth import verify_access_token
from tourist_safety_chatbot.api.routes import router as chatbot_router
from .routers import entities, reports
from .routers import dashboard
from .routers import medical
from .routers import itinerary
from .routers import safety_scores
from apscheduler.schedulers.background import BackgroundScheduler
from server.geofencing import init_geofence_db
from server.geofencing.scraper import news_scraper
from .routers import geofencing  # Import the geofencing router
from server.redis_client import redis_cache
from .routers import authority_alerts
from .routers import knowledge_base
from .routers import vector_db_generation
# ADD THIS IMPORT
from .routers import sse_stream  # NEW - SSE streaming endpoints
import subprocess
import atexit
from server.redis_client import check_redis_connection



# Security scheme
security = HTTPBearer()


def get_token_from_header(credentials: HTTPAuthorizationCredentials = Depends(security)):
    """Extract token from Authorization header"""
    return credentials.credentials

async def start_ipfs():
    """Check IPFS connection (Docker handles the daemon)"""
    # In Docker, we assume the 'ipfs' service is running. We don't spawn it.
    try:
        from .medical.ipfs_client import medical_ipfs_client
        if await medical_ipfs_client.is_connected():
            logger.info("✅ IPFS daemon is connected")
            return True
        else:
            logger.warning("⚠️ IPFS daemon not reachable yet")
            return False
    except Exception as e:
        logger.error(f"Failed to check IPFS: {e}")
        return False

def start_ganache():
    """Check Ganache connection (Docker handles the node)"""
    # In Docker, we assume the 'ganache' service is running.
    try:
        from .medical.blockchain_medical import medical_blockchain_manager
        if medical_blockchain_manager.connect():
            logger.info("✅ Ganache connected successfully")
            return True
        else:
            logger.warning("⚠️ Ganache node not reachable yet")
            return False
    except Exception as e:
        logger.error(f"Failed to check Ganache: {e}")
        return False

def stop_ipfs():
    """Stop IPFS daemon"""
    global ipfs_process
    if ipfs_process:
        try:
            logger.info("Stopping IPFS daemon...")
            ipfs_process.terminate()
            ipfs_process.wait(timeout=5)
            logger.info("IPFS daemon stopped")
        except Exception as e:
            logger.error(f"Error stopping IPFS: {e}")
            try:
                ipfs_process.kill()
            except:
                pass

def stop_ganache():
    """Stop Ganache"""
    global ganache_process
    if ganache_process:
        try:
            logger.info("Stopping Ganache...")
            ganache_process.terminate()
            ganache_process.wait(timeout=5)
            logger.info("Ganache stopped")
        except Exception as e:
            logger.error(f"Error stopping Ganache: {e}")
            try:
                ganache_process.kill()
            except:
                pass

# Startup and shutdown events
@asynccontextmanager
async def lifespan(app: FastAPI):
    """Handle application startup and shutdown"""
    logger.info("Starting DTID Server...")
    
    # Validate environment variables
    required_env_vars = ["MASTER_KEY", "JWT_SECRET_KEY", "CONTRACT_ADDRESS", "PRIVATE_KEY"]
    missing_vars = [var for var in required_env_vars if not os.getenv(var)]
    
    if missing_vars:
        logger.error(f"Missing required environment variables: {missing_vars}")
        raise Exception(f"Missing environment variables: {missing_vars}")
    
    try:
        logger.info("Initializing blockchain connection...")
        blockchain_status = init_blockchain()
        if blockchain_status and blockchain_status.get('connected'):
            logger.info(f"✅ Blockchain connected. Account: {blockchain_status.get('account')}")
        else:
            logger.warning("⚠️ Blockchain connection failed - operating in limited mode")
    except Exception as e:
        # Changed from 'raise' to 'logger.error' to prevent app crash
        logger.error(f"❌ Blockchain initialization failed: {e}")
        logger.info("Continuing startup... (Blockchain features will be disabled)")
    # Initialize blockchain
    try:
        logger.info("Initializing blockchain connection...")
        blockchain_status = init_blockchain()
        if blockchain_status.get('connected'):
            logger.info(f"Blockchain connected. Account: {blockchain_status.get('account')}")
            logger.info(f"Contract: {blockchain_status.get('contract_address')}")
            logger.info(f"Balance: {blockchain_status.get('balance_eth')} ETH")
        else:
            logger.error("Blockchain connection failed")
            raise Exception("Blockchain connection failed")
    except Exception as e:
        logger.error(f"Blockchain initialization failed: {e}")
        raise
    
    try:
        logger.info("Initializing Redis for SSE...")
        redis_ok = await check_redis_connection()
        if redis_ok:
            logger.info("✅ Redis connected - SSE streaming enabled")
        else:
            logger.warning("⚠️ Redis unavailable - SSE disabled, falling back to polling")
    except Exception as e:
        logger.error(f"Redis initialization failed: {e}")
    
    try:
        logger.info("Initializing geofencing system...")
        await asyncio.to_thread(init_geofence_db)
        logger.info("✅ Geofencing database initialized")
        
        # Start scheduler for hourly news scraping
        scheduler = BackgroundScheduler()
        scheduler.add_job(
            news_scraper.scrape_all_active_cities,
            'interval',
            hours=1,
            id='news_scraper',
            max_instances=1
        )
        scheduler.add_job(
            redis_cache.clear_expired,
            'interval',
            hours=6,
            id='cache_cleaner',
            max_instances=1
        )
        scheduler.start()
        logger.info("✅ Scheduler started (news scraping every 1h, cache cleaning every 6h)")
        
        # Store scheduler in app state for shutdown
        app.state.scheduler = scheduler
        
    except Exception as e:
        logger.error(f"Geofencing initialization failed: {e}")
        # Continue anyway - geofencing is non-critical
    
    try:
        logger.info("Initializing medical records system...")
        
        # Start IPFS
        if not await start_ipfs():
            logger.warning("IPFS failed to start - medical records may not work properly")
        
        # Start Ganache
        if not start_ganache():
            logger.warning("Ganache failed to start - medical blockchain may not work properly")
        
        logger.info("Medical records system initialized")
        
    except Exception as e:
        logger.error(f"Medical system initialization failed: {e}")
        
    try:
        flutter_tool = os.path.join(
            vector_db_generation.FLUTTER_PROJECT_ROOT,
            vector_db_generation.DART_GENERATOR_PATH
        )
        if not os.path.exists(flutter_tool):
            logger.warning(f"Flutter VDB generator not found at {flutter_tool}")
        else: 
            logger.info("Flutter Root Project Path Exists")
    except Exception as e:
        logger.error(f"Flutter tool check failed: {e}")
    
    # logger.info("DTID Server startup complete")
    
    
    
    logger.info("DTID Server startup complete")
    
    yield  # Server runs here
    
    # Shutdown logic
    logger.info("Shutting down DTID Server components...")
    
    # 1. Shutdown Scheduler immediately without waiting for pending jobs
    if hasattr(app.state, 'scheduler'):
        logger.info("Shutting down scheduler...")
        app.state.scheduler.shutdown(wait=False) 

    # 2. Close the safety calculator session
    await safety_calculator.close()
    
    # 3. These are globals in your code, ensure they don't block
    # In Docker, these are usually None anyway, but let's be safe
    stop_ipfs()
    stop_ganache()

    logger.info("Lifespan shutdown sequence complete.")


# Create FastAPI application
app = FastAPI(
    title="Digital Tourist ID (DTID) API",
    description="""
    A comprehensive Digital Tourist ID system with blockchain-based audit trail.
    
    ## Features
    * **Mobile Authentication**: SMS OTP-based registration and login
    * **Encrypted Data Storage**: AES-GCM encrypted personal data with DEK wrapping
    * **Blockchain Audit Trail**: Immutable logging of all data access and changes
    * **Tourist Groups**: Form groups with proximity alerts and location sharing
    * **Panic Button**: Emergency SOS with live location sharing and evidence upload
    * **AI Safety Monitoring**: Anomaly detection and safety scoring
    * **Verified Entities**: QR-code verified hotels, taxis, and service providers
    * **Authority Access Control**: Ethereum signature-based data access for authorities
    
    ## Authentication
    Most endpoints require JWT authentication. Include the token in the Authorization header:
    ```
    Authorization: Bearer <your_jwt_token>
    ```
    
    Get your token by:
    1. Register: `POST /auth/send-otp` → `POST /auth/register`
    2. Login: `POST /auth/send-otp` → `POST /auth/login`
    """,
    version="2.0.0",
    lifespan=lifespan,
    docs_url="/docs",
    redoc_url="/redoc"
)

app.add_middleware(
    CORSMiddleware,
    allow_origin_regex=r"https?://(localhost|127\.0\.0\.1)(:\d+)?|https://.*\.ngrok-free\.app",
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# Custom middleware for request logging
@app.middleware("http")
async def log_requests(request: Request, call_next):
    start_time = time.time()
    
    # Log the request
    logger.info(f"Request: {request.method} {request.url}")
    
    response = await call_next(request)
    
    # Log the response time
    process_time = time.time() - start_time
    logger.info(f"Response: {response.status_code} in {process_time:.4f}s")
    
    return response

# Include routers
app.include_router(auth.router)  # Authentication (no prefix, has /auth)
app.include_router(issuance.router)  # DTID issuance and profile management
app.include_router(access.router)  # Authority data access
app.include_router(groups.router)  # Tourist groups and Stay Connected
app.include_router(alerts.router)  # Alerts, SOS, and evidence
app.include_router(tracking.router)
app.include_router(chatbot_router, prefix="/api/chatbot", tags=["tourist-safety-chatbot"])
app.include_router(entities.router)  # Verified entities ecosystem
app.include_router(reports.router)   # Digital witness & rendezvous
app.include_router(dashboard.router)
app.include_router(medical.router)
app.include_router(itinerary.router)
app.include_router(geofencing.router)
app.include_router(authority_alerts.router)
app.include_router(knowledge_base.router)
app.include_router(vector_db_generation.router)
# ADD THIS LINE
app.include_router(sse_stream.router)  # SSE streaming for real-time updates
app.add_exception_handler(HTTPException, http_exception_handler)
app.add_exception_handler(ValidationError, validation_exception_handler)
app.include_router(safety_scores.router)
# Health check endpoints
@app.get("/")
async def root():
    """Root endpoint with basic system information"""
    return {
        "documentation": "/docs",
        "health": "/health",
        "authentication": "JWT with mobile OTP",
        "encryption": "AES-GCM with DEK wrapping"
    }

@app.get("/status")
async def service_status():
    return {
        "service": "Digital Tourist ID (DTID) API",
        "version": "2.0.0",
        "status": "operational",
        "features": [
            "Mobile OTP Authentication",
            "Encrypted Profile Storage",
            "Blockchain Audit Trail",
            "Tourist Groups",
            "Panic Button & Live Sharing",
            "Safety Monitoring",
            "Verified Entities",
            "Authority Access Control"
        ]
    }


@app.get("/health")
async def health_check():
    """Comprehensive health check endpoint"""
    try:
        from .db import check_database_connection
        from .blockchain import get_blockchain_manager
        
        health_status = {
            "status": "healthy",
            "timestamp": int(time.time() * 1000),
            "version": "2.0.0",
            "services": {}
        }
        
        # 1. Main Database (MySQL)
        db_healthy = check_database_connection()
        health_status["services"]["database"] = {
            "status": "healthy" if db_healthy else "unhealthy",
            "details": "Connected" if db_healthy else "Connection failed"
        }
        
        # 2. Blockchain (Main Ganache)
        try:
            blockchain = get_blockchain_manager()
            status_data = blockchain.check_connection()
            health_status["services"]["blockchain"] = {
                "status": "healthy" if status_data.get('connected') else "unhealthy",
                "details": status_data
            }
        except Exception as e:
            health_status["services"]["blockchain"] = {"status": "unhealthy", "details": str(e)}

        # 3. Medical IPFS
        try:
            from .medical.ipfs_client import medical_ipfs_client
            ipfs_info = await medical_ipfs_client.get_node_info()
            is_ok = ipfs_info.get("status") == "connected"
            health_status["services"]["medical_ipfs"] = {
                "status": "healthy" if is_ok else "unhealthy",
                "details": ipfs_info
            }
        except Exception as e:
            health_status["services"]["medical_ipfs"] = {"status": "unhealthy", "details": str(e)}

        # 4. Medical Blockchain (Ganache)
        try:
            from .medical.blockchain_medical import medical_blockchain_manager
            is_conn = medical_blockchain_manager.w3 and medical_blockchain_manager.w3.is_connected()
            health_status["services"]["medical_blockchain"] = {
                "status": "healthy" if is_conn else "unhealthy",
                "details": "connected" if is_conn else "disconnected"
            }
        except Exception as e:
            health_status["services"]["medical_blockchain"] = {"status": "unhealthy", "details": str(e)}
            
        # 5. Geofencing DB (Postgres) - FIX: Corrected duplicate logic
        try:
            from server.geofencing.database import geofence_engine
            with geofence_engine.connect() as conn:
                health_status["services"]["geofencing_db"] = {"status": "healthy", "details": "connected"}
        except Exception as e:
            health_status["services"]["geofencing_db"] = {"status": "unhealthy", "details": str(e)}

        # 6. BERT Models
        try:
            from server.geofencing.models import geofencing_models
            health_status["services"]["bert_models"] = {
                "status": "healthy" if geofencing_models.is_loaded else "degraded",
                "details": "Loaded" if geofencing_models.is_loaded else "Failed to load"
            }
        except Exception as e:
            health_status["services"]["bert_models"] = {"status": "unhealthy", "details": str(e)}

        # Final Overall Status
        all_ok = all(
            isinstance(s, dict) and s.get("status") == "healthy" 
            for s in health_status["services"].values()
        )
        health_status["status"] = "healthy" if all_ok else "degraded"
        
        return JSONResponse(content=health_status, status_code=200 if all_ok else 503)
        
    except Exception as e:
        logger.error(f"Critical Health check failure: {e}")
        return JSONResponse(
            status_code=503,
            content={"status": "unhealthy", "error": str(e)}
        )

@app.get("/config")
async def get_system_config():
    """Get system configuration information"""
    try:
        config = {
            "version": "2.0.0",
            "environment": os.getenv("ENVIRONMENT", "development"),
            "blockchain": {
                "rpc_url": os.getenv("RPC_URL", "http://127.0.0.1:8545"),
                "contract_address": os.getenv("CONTRACT_ADDRESS"),
                "network": "local-development"
            },
            "database": {
                "type": "MySQL",
                "connection_status": "checking..."
            },
            "authentication": {
                "method": "JWT + SMS OTP",
                "jwt_expiry_hours": 24,
                "otp_expiry_minutes": 5
            },
            "features": {
                "encryption": "AES-GCM 256-bit with DEK wrapping",
                "blockchain_audit": True,
                "signature_verification": "Ethereum ECDSA",
                "mobile_registration": True,
                "tourist_groups": True,
                "panic_button": True,
                "live_location_sharing": True,
                "evidence_upload": True,
                "safety_monitoring": True,
                "verified_entities": True
            },
            "security": {
                "master_key_configured": bool(os.getenv("MASTER_KEY")),
                "jwt_secret_configured": bool(os.getenv("JWT_SECRET_KEY")),
                "private_key_configured": bool(os.getenv("PRIVATE_KEY")),
                "mobile_pepper_configured": bool(os.getenv("MOBILE_HASH_PEPPER"))
            },
            "storage": {
                "evidence_directory": "storage/evidence",
                "max_file_size_mb": 50
            }
        }
        
        # Check database connection for config
        try:
            from .db import check_database_connection
            config["database"]["connection_status"] = "connected" if check_database_connection() else "disconnected"
        except:
            config["database"]["connection_status"] = "error"
        
        return config
        
    except Exception as e:
        logger.error(f"Config retrieval failed: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to get system configuration: {str(e)}"
        )

@app.get("/stats")
async def get_system_stats():
    """Get system statistics"""
    try:
        from .db import Tourist, Alert, TouristGroup, LiveShareSession, Evidence
        from .async_db import get_async_db
        from sqlalchemy import func
        from .async_db import get_db_session
        
        stats = {
            "timestamp": int(time.time() * 1000),
            "users": {},
            "alerts": {},
            "groups": {},
            "evidence": {},
            "blockchain": {}
        }
        
        async with get_db_session() as db:
            # User statistics
            result = await db.execute(
                select(func.count(Tourist.id))
            )
            total_users = result.scalar_one()

            result = (
                await db.execute(
                    select(func.count(Tourist.id))
                    .where(~Tourist.mobile_hash.like('admin-%'))
                )
            )
            
            mobile_users= result.scalar_one()

            result =await db.execute(
                        select(func.count(Tourist.id)).where(Tourist.mobile_hash.like('admin-%'))

			)
            admin_users= result.scalar_one()
            # Recent registrations (last 7 days)
            seven_days_ago = int((time.time() - 7*24*3600) * 1000)
            result = await db.execute(
                        select(func.count(Tourist.id)).where(Tourist.created_at >= seven_days_ago)

			)
            recent_registrations = result.scalar_one()
            
            stats["users"] = {
                "total": total_users,
                "mobile_registered": mobile_users,
                "admin_issued": admin_users,
                "recent_7d": recent_registrations
            }
            
            # Alert statistics
            result = (
                await db.execute(select(func.count(Alert.id)))
            )
            total_alerts= result.scalar_one()
            result = await db.execute(
                select(func.count(Alert.id))
                .where(Alert.status == 'ACTIVE')
            )
            active_alerts = result.scalar_one()

            result =  await db.execute(
                        select(func.count(Alert.id)).where(Alert.alert_type == 'SOS')

			)
            sos_alerts= result.scalar_one()
            result = await db.execute(
                        select(func.count(Alert.id)).where(Alert.created_at >= seven_days_ago)

			)
            recent_alerts= result.scalar_one()
            
            
            
            stats["alerts"] = {
                "total": total_alerts,
                "active": active_alerts,
                "sos_total": sos_alerts,
                "recent_7d": recent_alerts
            }
            
            # Group statistics
            result = await db.execute(
                        select(func.count(TouristGroup.id))

			)
            total_groups= result.scalar_one()
            result = await db.execute(
                        select(func.count(LiveShareSession.id)).where(LiveShareSession.status == 'ACTIVE')

			)
            active_sessions= result.scalar_one()
            stats["groups"] = {
                "total": total_groups,
                "active_live_sessions": active_sessions
            }
            
            # Evidence statistics
            result = await db.execute(
                        select(func.count(Evidence.id))

			)
            total_evidence= result.scalar_one()
            result = await db.execute(
                        select(Evidence.media_type, func.count(Evidence.id)).group_by(Evidence.media_type)

			)
            evidence_by_type = result.scalars().all()
            
            stats["evidence"] = {
                "total": total_evidence,
                "by_type": {str(media_type): count for media_type, count in evidence_by_type}
            }
        
        # Blockchain statistics
        try:
            from .blockchain import get_blockchain_manager
            blockchain = get_blockchain_manager()
            blockchain_status = blockchain.check_connection()
            
            stats["blockchain"] = {
                "connected": blockchain_status.get('connected', False),
                "latest_block": blockchain_status.get('latest_block'),
                "account_balance_eth": str(blockchain_status.get('balance_eth', 0))
            }
        except Exception as e:
            stats["blockchain"] = {"error": str(e)}
        
        return stats
        
    except Exception as e:
        logger.error(f"Stats retrieval failed: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to get system statistics: {str(e)}"
        )

# Global exception handler
@app.exception_handler(Exception)
async def global_exception_handler(request: Request, exc: Exception):
    """Global exception handler for unhandled errors"""
    logger.error(f"Unhandled exception on {request.method} {request.url}: {exc}", exc_info=True)
    
    return JSONResponse(
        status_code=500,
        content={
            "error": "Internal server error",
            "detail": "An unexpected error occurred. Please check the server logs.",
            "timestamp": int(time.time() * 1000),
            "path": str(request.url)
        }
    )

# Custom 404 handler
@app.exception_handler(404)
async def not_found_handler(request: Request, exc):
    return JSONResponse(
        status_code=404,
        content={
            "error": "Not Found",
            "detail": f"The requested endpoint {request.url.path} was not found.",
            "available_docs": "/docs"
        }
    )

if __name__ == "__main__":
    # Development server
    uvicorn.run(
        "server.main:app",
        host="0.0.0.0",
        port=8000,
        reload=True,
        log_level="info"
    )

    
# atexit.register(stop_ipfs)
# atexit.register(stop_ganache)