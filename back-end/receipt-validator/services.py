import jwt
import os
import requests
import logging
from dotenv import load_dotenv
from googleapiclient.discovery import build
from google.auth import default
from google.oauth2 import service_account
from google.api_core.exceptions import AlreadyExists
from fastapi import HTTPException, status

from appstoreserverlibrary.models.Environment import Environment
from appstoreserverlibrary.api_client import AppStoreServerAPIClient

from firebase_client import db
from firebase_admin import firestore

load_dotenv()

logger = logging.getLogger(__name__)

ISSUER_ID = os.getenv("APPLE_ISSUER_ID")
KEY_ID = os.getenv("APPLE_KEY_ID")
BUNDLE_ID = os.getenv("APPLE_BUNDLE_ID")

sandbox_client = None
prod_client = None

def verify_google_play_receipt(package_name: str, product_id: str, purchase_token: str) -> dict:
    """Валидация чека через Google Play Developer API."""
    try:
        CREDENTIALS_FILE = 'powwow-caller-bf08355a9620.json' 
        
        credentials = service_account.Credentials.from_service_account_file(CREDENTIALS_FILE)
        
        service = build('androidpublisher', 'v3', credentials=credentials)

        if product_id == "com.gys.powwow.subscription":
            result = service.purchases().subscriptions().get(
                packageName=package_name,
                subscriptionId=product_id,
                token=purchase_token
            ).execute()
        else:
            result = service.purchases().products().get(
                packageName=package_name,
                productId=product_id,
                token=purchase_token
            ).execute()

        return result
        
    except Exception as e:
        logger.error(f"Google Play API validation error: {e}")
        raise ValueError(f"Failed to contact Google Play API: {str(e)}")


try:
    with open("SubscriptionKey_HFCA6F69TR.p8", "rb") as f:
        PRIVATE_KEY = f.read()
        
    sandbox_client = AppStoreServerAPIClient(
        PRIVATE_KEY, KEY_ID, ISSUER_ID, BUNDLE_ID, Environment.SANDBOX
    )
    prod_client = AppStoreServerAPIClient(
        PRIVATE_KEY, KEY_ID, ISSUER_ID, BUNDLE_ID, Environment.PRODUCTION
    )
    logger.info("App Store Server API clients (Sandbox & Production) initialized successfully.")
    
except FileNotFoundError:
    logger.error("Apple .p8 key file not found! iOS validation will not work.")



def verify_apple_transaction(transaction_id: str, sandbox: bool = True) -> dict:
    """
    Проверка транзакции через App Store Server API (StoreKit 2).
    Флаг sandbox определяет, к какому серверу Apple стучаться.
    """
    client = sandbox_client if sandbox else prod_client

    if client is None:
        raise ValueError("Apple .p8 key is missing on the server. Cannot validate iOS receipts.")

    env_name = "SANDBOX" if sandbox else "PRODUCTION"

    try:
        response = client.get_transaction_info(transaction_id)
        
        if not response or not response.signedTransactionInfo:
            raise ValueError(f"Transaction not found or invalid in {env_name}")

        # Расшифровываем JWS
        transaction_data = jwt.decode(
            response.signedTransactionInfo, 
            options={"verify_signature": False}
        )
        
        return transaction_data

    except Exception as e:
        logger.error(f"App Store API ({env_name}) validation error: {e}")
        raise ValueError(f"Failed to contact App Store API ({env_name}): {str(e)}")


# def process_firestore_transaction(user_id: str, platform: str, product_id: str, store_transaction_id: str):
#     tx_ref = db.collection('purchase_transactions').document(store_transaction_id)
    
#     tx_data = {
#         'user_id': user_id,
#         'platform': platform,
#         'product_id': product_id,
#         'created_at': firestore.SERVER_TIMESTAMP
#     }

#     try:
#         tx_ref.create(tx_data)
#         logger.info(f"Successfully saved {platform} receipt {store_transaction_id} for user {user_id}")
        
#     except AlreadyExists:
#         existing_doc = tx_ref.get()
#         existing_data = existing_doc.to_dict()
        
#         if existing_data and existing_data.get('user_id') == user_id:
#             logger.info(f"Valid restore attempt for {platform} receipt {store_transaction_id} by user {user_id}")
#             return 
#         else:
#             logger.warning(f"Replay attack! Receipt {store_transaction_id} belongs to {existing_data.get('user_id')}, but {user_id} is trying to claim it.")
#             raise HTTPException(
#                 status_code=status.HTTP_409_CONFLICT, 
#                 detail="Receipt already processed by another user"
#             )

def process_firestore_transaction(user_id: str, platform: str, product_id: str, store_transaction_id: str):
    tx_ref = db.collection('purchase_transactions').document(store_transaction_id)
    
    # Сначала проверяем, есть ли уже этот чек в базе
    existing_doc = tx_ref.get()
    
    if existing_doc.exists:
        existing_data = existing_doc.to_dict()
        old_user_id = existing_data.get('user_id')
        
        if old_user_id == user_id:
            # Обычный Restore от того же юзера
            logger.info(f"Restore purchase for the same user: {user_id}")
            return
        else:
            # Юзер переустановил аппку (старый анонимный UID стерся)
            # или зашел под другим профилем, но Google Play аккаунт на устройстве тот же.
            # Делаем трансфер чека на новый актуальный user_id.
            logger.info(f"Transferring {platform} receipt {store_transaction_id} from old user {old_user_id} to new user {user_id}")
            
            tx_ref.update({
                'user_id': user_id,
                'updated_at': firestore.SERVER_TIMESTAMP
            })
            return
    else:
        #           Абсолютно новая покупка
        tx_data = {
            'user_id': user_id,
            'platform': platform,
            'product_id': product_id,
            'created_at': firestore.SERVER_TIMESTAMP,
            'updated_at': firestore.SERVER_TIMESTAMP
        }
        tx_ref.set(tx_data)
        logger.info(f"Successfully saved new {platform} receipt {store_transaction_id} for user {user_id}")