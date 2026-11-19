import logging
import socketio
import uvicorn
from fastapi import FastAPI
from typing import Dict

# Configure logging
logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")
logger = logging.getLogger(__name__)

app = FastAPI()
sio = socketio.AsyncServer(async_mode='asgi', cors_allowed_origins='*')
socket_app = socketio.ASGIApp(sio, other_asgi_app=app)

connected_users: Dict[str, str] = {}


@sio.event
async def connect(sid: str, environ: dict, auth: dict) -> None:
    if not auth or 'uid' not in auth:
        logger.warning(f"Connection refused (sid: {sid}): 'uid' missing.")
        raise socketio.exceptions.ConnectionRefusedError('UID is required in auth')

    uid = str(auth['uid'])

    async with sio.session(sid) as session:
        session['uid'] = uid

    connected_users[uid] = sid
    logger.info(f"[+] Connected: {uid} (sid: {sid})")


@sio.event
async def disconnect(sid: str) -> None:
    async with sio.session(sid) as session:
        uid = session.get('uid')

        if uid and connected_users.get(uid) == sid:
            del connected_users[uid]
            logger.info(f"[-] Disconnected: {uid}")


@sio.event
async def message(sid: str, payload: dict) -> None:
    target_uid = payload.get('to')
    msg_type = payload.get('type')

    async with sio.session(sid) as session:
        sender_uid = session.get('uid')

    if not target_uid:
        await sio.emit('error', {'message': 'The "to" field is required'}, room=sid)
        return

    target_uid = str(target_uid)

    if target_uid in connected_users:
        target_sid = connected_users[target_uid]

        payload['from'] = sender_uid

        await sio.emit('message', payload, room=target_sid)
        logger.info(f"[>] Forwarded (type: {msg_type}) from {sender_uid} to {target_uid}")
    else:
        logger.info(f"[x] Delivery failed: {target_uid} is offline (from {sender_uid})")
        await sio.emit('error', {'message': f'User {target_uid} is offline'}, room=sid)


if __name__ == '__main__':
    uvicorn.run("main:socket_app", host="0.0.0.0", port=8000, reload=False)