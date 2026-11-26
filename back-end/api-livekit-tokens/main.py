import os
import time
import logging
import jwt
from fastapi import FastAPI, Depends, HTTPException
from pydantic import BaseModel
from dotenv import load_dotenv

from connection import verify_user

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(name)s - %(message)s"
)
logger = logging.getLogger(__name__)

load_dotenv()

app = FastAPI()

class TokenRequest(BaseModel):
    userId: str
    tribeID: str
    name: str = "Participant"
    roomJoin: bool = True
    canPublish: bool = True
    canSubscribe: bool = True
    canPublishData: bool = True

@app.post("/api/livekit/tokens")
async def generate_livekit_token(req: TokenRequest, user: dict = Depends(verify_user)):
    logger.info(f"Received request to generate standard JWT token. userId: {req.userId}, tribeID: {req.tribeID}")

    try:
        api_key = os.getenv("livekitApiKey")
        api_secret = os.getenv("livekitApiSecret")
        livekit_url = os.getenv("livekitUrl")

        if not api_key or not api_secret:
            logger.error("LiveKit API keys are missing")
            raise HTTPException(status_code=500, detail="Internal server error")

        now = int(time.time())
        ttl = 3600

        payload = {
            "iss": api_key,
            "sub": req.userId,
            "nbf": now,
            "exp": now + ttl,
            "name": req.name,
            "metadata": "",
            "attributes": {},
            "video": {
                "room": req.tribeID,
                "roomJoin": req.roomJoin,
                "canPublish": req.canPublish,
                "canSubscribe": req.canSubscribe,
                "canPublishData": req.canPublishData,
            }
        }

        token = jwt.encode(payload, api_secret, algorithm="HS256")

        logger.info(f"Successfully generated standard JWT for userId: {req.userId} in room: {req.tribeID}")

        return {
            "token": token,
            "url": livekit_url
        }

    except Exception as e:
        logger.error(f"Error generating JWT token: {str(e)}")
        raise HTTPException(status_code=500, detail="Failed to generate token")


if __name__ == "__main__":
    import uvicorn

    logger.info("Starting API server for JWT generation...")
    uvicorn.run(app, host="0.0.0.0", port=8000)