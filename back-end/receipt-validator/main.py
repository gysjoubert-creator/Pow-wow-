from fastapi import FastAPI
from routers import router as purchases_router

app = FastAPI(
    title="In-App Purchase Validator API",
    description="Server-side validation for Google Play and App Store receipts",
    version="1.0.0"
)

# Подключаем роутер с эндпойнтами
app.include_router(purchases_router)

# Healthcheck эндпойнт для Cloud Run
@app.get("/health")
def health_check():
    return {"status": "ok"}