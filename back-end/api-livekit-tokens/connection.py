import logging
import firebase_admin
from fastapi import Depends, HTTPException
from fastapi.security import APIKeyHeader
from firebase_admin import credentials, auth

logger = logging.getLogger(__name__)

cred = credentials.Certificate("powwow-caller.json")
firebase_admin.initialize_app(cred)

security = APIKeyHeader(name="Authorization", auto_error=False)

async def verify_user(token: str = Depends(security)):
    if not token:
        logger.warning("Authentication failed: Token is missing")
        raise HTTPException(status_code=401)

    try:
        decoded_token = auth.verify_id_token(token)
        uid = decoded_token.get('uid')
        logger.info(f"User {uid} authenticated successfully via Firebase")
        return {"userId": uid, "isVerified": True}

    except auth.ExpiredIdTokenError:
        logger.warning("Authentication failed")
        raise HTTPException(status_code=401)
    except auth.InvalidIdTokenError:
        logger.warning("Authentication failed: Invalid Firebase token")
        raise HTTPException(status_code=401)
    except Exception as e:
        logger.error(f"Firebase token validation error: {str(e)}")
        raise HTTPException(status_code=401)