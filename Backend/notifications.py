# server/notifications.py
import os
import logging
import firebase_admin
from firebase_admin import credentials, messaging
from typing import List, Dict, Any

from sqlalchemy import select

from .db import Tourist
from .async_db import get_db_session
from fastapi.concurrency import run_in_threadpool
from sqlalchemy import select
from .async_db import get_db_session
logger = logging.getLogger(__name__)

# --- Firebase Initialization ---
try:
    # Path to your Firebase service account key JSON file
    # Store this securely, do not commit to Git!
    SERVICE_ACCOUNT_KEY_PATH = os.getenv("FIREBASE_SERVICE_ACCOUNT_KEY_PATH")

    if SERVICE_ACCOUNT_KEY_PATH and os.path.exists(SERVICE_ACCOUNT_KEY_PATH):
        cred = credentials.Certificate(SERVICE_ACCOUNT_KEY_PATH)
        firebase_admin.initialize_app(cred)
        logger.info("Firebase Admin SDK initialized successfully.")
        FCM_ENABLED = True
    else:
        logger.warning("FIREBASE_SERVICE_ACCOUNT_KEY_PATH not set or file not found. Push notifications are disabled.")
        FCM_ENABLED = False
except Exception as e:
    logger.error(f"Failed to initialize Firebase Admin SDK: {e}")
    FCM_ENABLED = False


def send_push_notification(
    fcm_token: str,
    title: str,
    body: str,
    data: Dict[str, str] = None
) -> bool:
    """Sends a single push notification to a device."""
    if not FCM_ENABLED or not fcm_token:
        return False
    
    message = messaging.Message(
        notification=messaging.Notification(title=title, body=body),
        token=fcm_token,
        data=data or {},
    )

    try:
        response = messaging.send(message)
        logger.info(f"Successfully sent FCM message: {response}")
        return True
    except Exception as e:
        logger.error(f"Failed to send FCM message to token {fcm_token}: {e}")
        return False

async def send_notification_to_user(
    user_id: str,
    title: str,
    body: str,
    data: Dict[str, str] = None
):
    async with get_db_session() as db:
        result = await db.execute(
            select(Tourist).where(Tourist.id == user_id)
        )
        user = result.scalars().first()

    if not user or not user.fcm_token:
        logger.warning(f"User {user_id} not found or no FCM token")
        return False

    # 🔑 CRITICAL: offload Firebase send
    return await run_in_threadpool(
        send_push_notification,
        user.fcm_token,
        title,
        body,
        data
    )