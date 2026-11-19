import os
import time
import uuid
import httpx
import jwt
from fastapi import FastAPI, HTTPException, Depends
from fastapi.security import APIKeyHeader
from pydantic import BaseModel
from firebase_admin import auth, messaging
from dotenv import load_dotenv

from connection import db

load_dotenv()
APPLE_TEAM_ID = os.getenv('APPLE_TEAM_ID')
APPLE_KEY_ID = os.getenv('APPLE_KEY_ID')
APPLE_BUNDLE_ID = os.getenv('APPLE_BUNDLE_ID')
APPLE_P8_FILE_PATH = os.getenv('APPLE_P8_FILE_PATH')

app = FastAPI(title="Push Call API")

security = APIKeyHeader(name="Authorization", auto_error=False)


async def verify_user(token: str = Depends(security)):
    if not token:
        print("Authentication failed: Token is missing")
        raise HTTPException(status_code=401, detail="Token is missing")

    try:
        decoded_token = auth.verify_id_token(token)
        uid = decoded_token.get('uid')
        print(f"User {uid} authenticated successfully")
        return {"userId": uid, "isVerified": True}

    except auth.ExpiredIdTokenError:
        print("Authentication failed: Token expired")
        raise HTTPException(status_code=401, detail="Token expired")
    except auth.InvalidIdTokenError:
        print("Authentication failed: Invalid Firebase token")
        raise HTTPException(status_code=401, detail="Invalid token")
    except Exception as e:
        print(f"Firebase token validation error: {str(e)}")
        raise HTTPException(status_code=401, detail="Authentication failed")


class CallRequest(BaseModel):
    targetUserId: str
    tribeId: str 


def send_voip_push_google(device_token: str, caller_name: str, call_uuid: str, tribe_id: str):
    message = messaging.Message(
        token=device_token,
        data={
            'type': 'INCOMING_CALL',
            'callerName': caller_name or 'Unknown',
            'callUUID': call_uuid,
            'handle': '+123456789',
            'tribeId': tribe_id or '' 
        },
        android=messaging.AndroidConfig(priority='high', ttl=0)
    )

    try:
        response = messaging.send(message)
        print(f"FCM Push successfully sent: {response}")
        return response
    except Exception as e:
        print(f"Error sending FCM message: {e}")
        raise HTTPException(status_code=500, detail=f"FCM Error: {str(e)}")


async def send_voip_push_apple(device_token: str, caller_name: str, call_uuid: str, tribe_id: str, environment: str):
    try:
        with open(APPLE_P8_FILE_PATH, 'r') as f:
            private_key = f.read()
    except FileNotFoundError:
        raise HTTPException(status_code=500, detail="Apple P8 key file not found")

    token = jwt.encode(
        {'iss': APPLE_TEAM_ID, 'iat': int(time.time())},
        private_key,
        algorithm='ES256',
        headers={'kid': APPLE_KEY_ID}
    )

    headers = {
        'authorization': f'bearer {token}',
        'apns-topic': f'{APPLE_BUNDLE_ID}.voip',
        'apns-push-type': 'voip',
        'apns-priority': '10',
        'apns-expiration': '0'
    }

    payload = {
        'aps': {'content-available': 1},
        'callUUID': call_uuid,
        'callerName': caller_name or 'Unknown',
        'tribeId': tribe_id,
    }

    if environment == 'production':
        apns_base_url = 'https://api.push.apple.com'
    else:
        apns_base_url = 'https://api.sandbox.push.apple.com'

    url = f'{apns_base_url}/3/device/{device_token}'

    async with httpx.AsyncClient(http2=True) as client:
        response = await client.post(
            url,
            headers=headers,
            json=payload
        )

    if response.status_code == 200:
        print(f"APNs Push successfully sent to {environment}")
        return True
    else:
        print(f"APNs Error: {response.text}")
        raise HTTPException(status_code=500, detail=f"APNs Error: {response.text}")


@app.post("/api/call")
async def make_call(request: CallRequest, current_user: dict = Depends(verify_user)):
    caller_id = current_user["userId"]
    target_user_id = request.targetUserId
    
    caller_doc = db.collection('users').document(caller_id).get()

    caller_name = 'Unknown'

    if caller_doc.exists:
        caller_data = caller_doc.to_dict()
        caller_name = caller_data.get('name', caller_name)

    token_doc = db.collection('tokens').document(target_user_id).get()

    if not token_doc.exists:
        print(f"Target user ID '{target_user_id}' not found in tokens collection")
        raise HTTPException(status_code=404, detail=f"Target user ID '{target_user_id}' not found")

    token_data = token_doc.to_dict()
    token_voip = token_data.get('tokenVoIP')
    token_fcm = token_data.get('tokenFCM')
    
    push_environment = token_data.get('pushEnvironment', 'development')

    call_uuid = str(uuid.uuid4())

    if token_voip:
        print(f"Sending iOS VoIP push to {target_user_id} (Env: {push_environment})")
        await send_voip_push_apple(token_voip, caller_name, call_uuid, request.tribeId, push_environment)
        return {"success": True, "platform": "ios", "callUUID": call_uuid}

    elif token_fcm:
        print(f"Sending Android FCM push to {target_user_id}")
        send_voip_push_google(token_fcm, caller_name, call_uuid, request.tribeId)
        return {"success": True, "platform": "android", "callUUID": call_uuid}

    else:
        print(f"No valid tokens found for user {target_user_id}")
        raise HTTPException(status_code=400, detail="User has no valid push tokens")