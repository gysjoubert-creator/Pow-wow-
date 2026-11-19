from fastapi import HTTPException, Header, status, Depends
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from firebase_admin import auth
import logging

logger = logging.getLogger(__name__)
security = HTTPBearer()


async def get_current_user(authorization: str = Header(..., description="Firebase token (with or without 'Bearer ')")):

    token = authorization

    if token.startswith("Bearer "):
        token = token.split(" ")[1]

    try:
        decoded_token = auth.verify_id_token(token)
        uid = decoded_token.get('uid')
        logger.info(f"User {uid} authenticated successfully")
        return {"uid": uid, "isVerified": True}

    except auth.ExpiredIdTokenError:
        logger.warning("Authentication failed: Token expired")
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Token expired")
        
    except auth.InvalidIdTokenError:
        logger.warning("Authentication failed: Invalid Firebase token")
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token")
        
    except Exception as e:
        logger.error(f"Firebase token validation error: {str(e)}")
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Authentication failed")