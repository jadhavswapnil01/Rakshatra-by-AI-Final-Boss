# server/dependencies.py
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
import os
import jwt
from datetime import datetime, timedelta
from typing import Dict, Any

# Define the security scheme here
security = HTTPBearer()

def get_token_from_header(credentials: HTTPAuthorizationCredentials = Depends(security)):
    """Extracts the token from the 'Authorization: Bearer <token>' header."""
    if not credentials:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Authentication credentials were not provided"
        )
    return credentials.credentials

# --- NEW: token verification helper (moved from server/routers/auth.py) ---
JWT_SECRET_KEY = os.getenv("JWT_SECRET_KEY", "your-super-secret-jwt-key-change-in-production")
JWT_ALGORITHM = "HS256"

def verify_access_token(token: str) -> Dict[str, Any]:
    """Verify JWT access token and return payload (raises HTTPException on failure)."""
    try:
        payload = jwt.decode(token, JWT_SECRET_KEY, algorithms=[JWT_ALGORITHM])
        return payload
    except jwt.ExpiredSignatureError:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Token has expired"
        )
    except jwt.PyJWTError:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid token"
        )
