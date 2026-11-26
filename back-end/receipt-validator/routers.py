from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, status
from google.api_core.exceptions import AlreadyExists
from firebase_admin import firestore
import logging

from schemas import GooglePurchasePayload, AppleTransactionRequest
from services import verify_google_play_receipt, verify_apple_transaction, process_firestore_transaction
from dependencies import get_current_user
from firebase_client import db

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api/v1/purchases", tags=["Receipt Validation"])


def format_iso_date(timestamp_ms):
    """Конвертирует миллисекунды в формат 2026-07-06T10:03:04.000Z"""
    if not timestamp_ms:
        return None
    dt = datetime.fromtimestamp(int(timestamp_ms) / 1000, tz=timezone.utc)
    return dt.strftime('%Y-%m-%dT%H:%M:%S.000Z')


def _process_apple_purchase(current_user: dict, apple_data: dict, env: str):
    transaction_id = apple_data.get("transactionId")
    product_id = apple_data.get("productId")
    
    # StoreKit 2 отдает даты в миллисекундах
    expires_date_ms = apple_data.get("expiresDate")
    revocation_date_ms = apple_data.get("revocationDate") # Если покупку вернули (Refund)

    if not transaction_id or not product_id:
        logger.error(f"Incomplete data from Apple ({env}): {apple_data}")
        raise HTTPException(status_code=400, detail="Incomplete transaction data from Apple")

    try:
        process_firestore_transaction(
            current_user['uid'], 
            'ios', 
            product_id, 
            str(transaction_id)
        )
    except HTTPException:
        raise
    except Exception as db_error:
        logger.error(f"Firestore crash: {str(db_error)}")
        raise HTTPException(status_code=500, detail="Failed to save transaction to database")

    now = datetime.now(timezone.utc)
    validated_at = now.strftime('%Y-%m-%dT%H:%M:%S.000Z')
    
    if revocation_date_ms:
        active = False
        expires_at_str = format_iso_date(revocation_date_ms)
    elif expires_date_ms:
        expires_dt = datetime.fromtimestamp(int(expires_date_ms) / 1000, tz=timezone.utc)
        active = expires_dt > now
        expires_at_str = expires_dt.strftime('%Y-%m-%dT%H:%M:%S.000Z')
    else:
        active = True
        expires_at_str = None

    client_env = "sandbox" if "sandbox" in env.lower() else "production"
    
    return {
        "status": "success",
        "message": "iOS purchase validated successfully",
        "active": active,
        "productId": product_id,
        "store": "app_store",
        "environment": client_env,
        "expiresAt": expires_at_str,
        "validatedAt": validated_at,
        "willRenew": None
    }


@router.post("/validate/ios/sandbox", summary="Валидация iOS (Песочница)")
async def validate_ios_sandbox(payload: AppleTransactionRequest, current_user: dict = Depends(get_current_user)):
    try:
        apple_data = verify_apple_transaction(payload.transaction_id, sandbox=True)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))

    return _process_apple_purchase(current_user, apple_data, env="sandbox")


@router.post("/validate/ios/production", summary="Валидация iOS (Продакшен)")
async def validate_ios_production(payload: AppleTransactionRequest, current_user: dict = Depends(get_current_user)):
    try:
        apple_data = verify_apple_transaction(payload.transaction_id, sandbox=False)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))

    return _process_apple_purchase(current_user, apple_data, env="production")


@router.post("/validate/android", summary="Валидация Android")
async def validate_android_purchase(payload: GooglePurchasePayload, current_user: dict = Depends(get_current_user)):
    try:
        google_data = verify_google_play_receipt(
            package_name=payload.package_name,
            product_id=payload.product_id,
            purchase_token=payload.purchase_token
        )
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))

    try:
        process_firestore_transaction(
            current_user['uid'], 
            'android', 
            payload.product_id, 
            payload.purchase_token
        )
    except Exception as db_error:
        logger.error(f"Firestore crash: {str(db_error)}")
        raise HTTPException(status_code=500, detail="Failed to save transaction to database")

    now = datetime.now(timezone.utc)
    validated_at = now.strftime('%Y-%m-%dT%H:%M:%S.000Z')

    expiry_millis = google_data.get("expiryTimeMillis") 
    auto_renewing = google_data.get("autoRenewing")

    if expiry_millis:
        expires_dt = datetime.fromtimestamp(int(expiry_millis) / 1000, tz=timezone.utc)
        active = expires_dt > now
        expires_at_str = expires_dt.strftime('%Y-%m-%dT%H:%M:%S.000Z')
    else:
        active = True
        expires_at_str = None

    return {
        "status": "success",
        "message": "Android purchase validated successfully",
        "active": active,
        "productId": payload.product_id,
        "store": "play_store",
        "environment": None,  
        "expiresAt": expires_at_str,
        "validatedAt": validated_at,
        "willRenew": auto_renewing
    }


@router.get("/products", summary="Получить список доступных товаров")
async def get_products(current_user: dict = Depends(get_current_user)):
    """
    Возвращает список идентификаторов товаров для iOS и Android.
    Мобильное приложение использует эти ID для запроса актуальных цен у Apple/Google.
    """
    
    products_data = {
        "ios": [
            {
                "product_id": "com.gys.powwow.year",
                "type": "subscription",
                "duration": "1 year"
            },
            {
                "product_id": "com.gys.powwow.month",
                "type": "subscription",
                "duration": "1 month"
            },
            {
                "product_id": "com.gys.powwow.week",
                "type": "subscription",
                "duration": "1 week"
            },
            {
                "product_id": "com.gys.powwow.life",
                "type": "non-consumable",
                "duration": "lifelong"
            }
        ],
        "android": [
            {
                "product_id": "com.gys.powwow.subscription",
                "base_plan": "year",
                "type": "subscription",
                "duration": "1 year"
            },
            {
                "product_id": "com.gys.powwow.subscription",
                "base_plan": "monthly",
                "type": "subscription",
                "duration": "1 month"
            },
            {
                "product_id": "com.gys.powwow.subscription",
                "base_plan": "weekly",
                "type": "subscription",
                "duration": "1 week"
            },
            {
                "product_id": "com.gys.powwow.one.time",
                "base_plan": None,
                "type": "non-consumable",
                "duration": "lifelong"
            }
        ]
    }

    return {
        "status": "success",
        "data": products_data
    }