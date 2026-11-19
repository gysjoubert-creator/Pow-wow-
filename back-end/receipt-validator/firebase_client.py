import firebase_admin
from firebase_admin import credentials, firestore

cred = credentials.Certificate("powwow-caller-bf08355a9620.json")
firebase_admin.initialize_app(cred)

db = firestore.client()