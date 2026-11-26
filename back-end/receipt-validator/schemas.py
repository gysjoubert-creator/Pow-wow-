from pydantic import BaseModel, Field

class AppleTransactionRequest(BaseModel):
    transaction_id: str

class GooglePurchasePayload(BaseModel):
    package_name: str
    product_id: str
    purchase_token: str