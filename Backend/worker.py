# Backend/server/worker.py
"""
Celery Configuration for Background Task Processing

WHY CELERY?
Your current setup blocks the main thread when:
1. Analyzing medical documents (30-60 seconds)
2. Processing face recognition (5-10 seconds)
3. Running BERT geofence analysis (2-5 seconds)
4. Scraping news for geofences (10+ seconds)

With Celery, these tasks run in SEPARATE processes, keeping your API responsive.

HOW IT WORKS:
1. API receives request → Creates task → Returns task ID immediately
2. Celery worker picks up task → Processes in background
3. Frontend polls for status OR receives SSE notification when complete
"""

import os
import logging
from datetime import timedelta

from celery import Celery
from celery.schedules import crontab

logger = logging.getLogger(__name__)

# ============================================
# Celery Configuration
# ============================================

# Redis URLs for broker and backend
CELERY_BROKER_URL = os.getenv("CELERY_BROKER_URL", "redis://redis:6379/1")
CELERY_RESULT_BACKEND = os.getenv("CELERY_RESULT_BACKEND", "redis://redis:6379/2")

# Create Celery app
celery_app = Celery(
    "dtid_worker",
    broker=CELERY_BROKER_URL,
    backend=CELERY_RESULT_BACKEND,
    include=[
        "server.tasks.medical_tasks",
        "server.tasks.face_tasks",
        "server.tasks.geofence_tasks",
        "server.tasks.notification_tasks",
    ]
)

# ============================================
# Celery Settings
# ============================================

celery_app.conf.update(
    # Task execution settings
    task_serializer="json",
    accept_content=["json"],
    result_serializer="json",
    timezone="Asia/Kolkata",
    enable_utc=True,
    
    # Task result settings
    result_expires=3600,  # Results expire after 1 hour
    task_track_started=True,
    task_time_limit=600,  # 10 minute hard limit
    task_soft_time_limit=300,  # 5 minute soft limit
    
    # Worker settings
    worker_prefetch_multiplier=1,  # One task at a time per worker
    worker_concurrency=2,  # 2 worker threads (adjust based on CPU)
    
    # Task routes (optional - for separating AI tasks to dedicated workers)
    task_routes={
        "server.tasks.medical_tasks.*": {"queue": "medical"},
        "server.tasks.face_tasks.*": {"queue": "face"},
        "server.tasks.geofence_tasks.*": {"queue": "geofence"},
        "server.tasks.notification_tasks.*": {"queue": "notifications"},
    },
    
    # Default queue for tasks without explicit route
    task_default_queue="default",
    
    # Retry settings
    task_acks_late=True,
    task_reject_on_worker_lost=True,
)

# ============================================
# Scheduled Tasks (Celery Beat)
# ============================================

celery_app.conf.beat_schedule = {
    # Scrape news for geofences every 30 minutes
    "scrape-news-geofences": {
        "task": "server.tasks.geofence_tasks.scrape_all_cities",
        "schedule": timedelta(minutes=30),
        "options": {"queue": "geofence"},
    },
    
    # Clean up expired geofences daily at midnight
    "cleanup-expired-geofences": {
        "task": "server.tasks.geofence_tasks.cleanup_expired",
        "schedule": crontab(hour=0, minute=0),
        "options": {"queue": "geofence"},
    },
    
    # Check for inactive tourists (anomaly detection) every 5 minutes
    "check-tourist-inactivity": {
        "task": "server.tasks.notification_tasks.check_inactivity",
        "schedule": timedelta(minutes=5),
        "options": {"queue": "notifications"},
    },
    
    # Clean up old cache entries every hour
    "cache-cleanup": {
        "task": "server.tasks.notification_tasks.cleanup_cache",
        "schedule": timedelta(hours=1),
        "options": {"queue": "default"},
    },
}


# ============================================
# Task Decorators (Convenience)
# ============================================

def create_task(name: str, **options):
    """Create a Celery task with standard options"""
    return celery_app.task(
        name=name,
        bind=True,  # Include self parameter for retries
        autoretry_for=(Exception,),
        retry_backoff=True,
        retry_backoff_max=600,
        retry_jitter=True,
        max_retries=3,
        **options
    )


# ============================================
# Task Status Tracking
# ============================================

class TaskStatus:
    """Task status constants"""
    PENDING = "PENDING"
    STARTED = "STARTED"
    PROGRESS = "PROGRESS"
    SUCCESS = "SUCCESS"
    FAILURE = "FAILURE"
    REVOKED = "REVOKED"


def get_task_status(task_id: str) -> dict:
    """
    Get status of a Celery task.
    
    Returns:
        {
            "task_id": "xxx",
            "status": "PROGRESS",
            "progress": 50,
            "message": "Analyzing document...",
            "result": null  # Populated on SUCCESS
        }
    """
    from celery.result import AsyncResult
    
    result = AsyncResult(task_id, app=celery_app)
    
    response = {
        "task_id": task_id,
        "status": result.status,
        "progress": 0,
        "message": "",
        "result": None,
    }
    
    if result.status == "PENDING":
        response["message"] = "Task is waiting to be processed"
        
    elif result.status == "STARTED":
        response["message"] = "Task has started"
        
    elif result.status == "PROGRESS":
        # Custom progress info stored in result.info
        info = result.info or {}
        response["progress"] = info.get("progress", 0)
        response["message"] = info.get("message", "Processing...")
        
    elif result.status == "SUCCESS":
        response["progress"] = 100
        response["message"] = "Task completed successfully"
        response["result"] = result.result
        
    elif result.status == "FAILURE":
        response["message"] = str(result.result)
        
    elif result.status == "REVOKED":
        response["message"] = "Task was cancelled"
    
    return response


# ============================================
# Celery Signals (Event Hooks)
# ============================================

from celery.signals import task_success, task_failure, task_prerun, task_postrun


@task_prerun.connect
def task_prerun_handler(sender=None, task_id=None, task=None, args=None, kwargs=None, **extra):
    """Log when task starts"""
    logger.info(f"🚀 Task starting: {task.name} [{task_id}]")


@task_postrun.connect
def task_postrun_handler(sender=None, task_id=None, task=None, args=None, kwargs=None, retval=None, state=None, **extra):
    """Log when task completes"""
    logger.info(f"✅ Task completed: {task.name} [{task_id}] - State: {state}")


@task_success.connect
def task_success_handler(sender=None, result=None, **kwargs):
    """Handle successful task completion"""
    # Optionally publish to Redis for SSE notification
    pass


@task_failure.connect
def task_failure_handler(sender=None, task_id=None, exception=None, traceback=None, **kwargs):
    """Handle task failure"""
    logger.error(f"❌ Task failed: {sender.name} [{task_id}] - {exception}")


# ============================================
# Usage Example
# ============================================

"""
HOW TO USE IN YOUR ROUTERS:

1. Import the task:
    from server.tasks.medical_tasks import analyze_medical_document_task

2. Trigger the task (non-blocking):
    task = analyze_medical_document_task.delay(
        file_content_base64="...",
        filename="report.pdf",
        tourist_id="DTID-XXX",
        file_hash="abc123..."
    )
    
    # Return immediately with task ID
    return {"task_id": task.id, "status": "PROCESSING"}

3. Check status (polling endpoint):
    @router.get("/task/{task_id}")
    async def get_task_status(task_id: str):
        from server.worker import get_task_status
        return get_task_status(task_id)

4. Or use SSE for real-time updates (recommended)
"""
