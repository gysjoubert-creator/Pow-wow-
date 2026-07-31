# In-App Purchases API (receipt-validator)

This document describes the purchases API contract PowWow currently has for App Store / Google Play validation. The primary contract artifact from the backend team is the Postman collection in this repository. Extra notes below separate confirmed live observations from client-side fallback behavior and backend action items.

Client code: `lib/app/services/subscriptions/` (see the "In-app purchases / subscriptions" section of [`docs/current-state.md`](current-state.md) for an overview of the Flutter-side architecture).

Postman collection (primary source of truth from the backend team, with `base_url` pointed at production): [`docs/postman/powwow-purchases-api.postman_collection.json`](postman/powwow-purchases-api.postman_collection.json). The copy in this repository may include confirmed corrections from live API checks; those corrections are called out below.

Important current limitation: the Postman collection documents request bodies but does **not** document success response bodies for purchase validation endpoints (`"response": []`). Any `expiresAt`/`active` fields mentioned in this document are therefore client-side expectations, parsed live observations, or requested backend contract fixes unless a real full validation response is captured and added to Postman.

## Base URL

- Production default (baked into `SubscriptionBackendClient.defaultBaseUrl`): `https://receipt-validator-237694335752.us-central1.run.app`.
- Override at build/run time with `--dart-define=POWWOW_IAP_API_BASE_URL=<url>` (e.g. to point at a local/staging instance of the validator during development).

## Authentication

Every purchases endpoint (including, in practice, `GET /products` — see [Known discrepancies](#known-discrepancies-vs-the-postman-collection) below) requires a Firebase ID token in the `Authorization` header:

```
Authorization: <firebase_id_token>
```

The server accepts the token with or without a `Bearer ` prefix (it strips the prefix itself if present). The Flutter client sends the raw token (`AuthService.getFirebaseIdToken()`), no prefix.

## Endpoints

### `POST /api/v1/purchases/validate/ios/sandbox` and `POST /api/v1/purchases/validate/ios/production`

Validates an Apple purchase using the **StoreKit 2** transaction API. There are two separate endpoints depending on the purchase environment:

- `/sandbox` — Sandbox and TestFlight purchases.
- `/production` — Real App Store purchases.

The Flutter client automatically selects the correct endpoint by decoding the `environment` field from the JWS payload in `purchase.verificationData.serverVerificationData`. If the JWS cannot be decoded (or the field is absent), the client defaults to `/sandbox`.

Request body:

```json
{
  "transaction_id": "<string>"
}
```

- `transaction_id` — the StoreKit 2 transaction identifier, sent as `purchase.purchaseId` from `in_app_purchase` (maps to `SK2Transaction.id`, a numeric string like `"2000000123456789"`). If `purchaseId` is null (rare edge-case), the client extracts `transactionId` from the JWS payload as a fallback.

The client-side mapping lives in `SubscriptionBackendClient._validationPath()` and `._validationBody()`. The JWS environment detection is in `._isIosProductionJws()`.

### `POST /api/v1/purchases/validate/android`

Validates a Google Play purchase (subscription or one-time/lifetime product).

Request body:

```json
{
  "package_name": "com.gys.powwow",
  "product_id": "com.gys.powwow.subscription",
  "purchase_token": "<string>"
}
```

- `package_name` — the Android application ID. Hardcoded as `SubscriptionProductIds.androidPackageName` (`com.gys.powwow`, matching `android/app/build.gradle.kts`).
- `product_id` — the Play Store product/subscription ID being purchased (`purchase.productId` from `in_app_purchase`, e.g. `com.gys.powwow.subscription` or `com.gys.powwow.one.time`).
- `purchase_token` — `purchase.verificationData.serverVerificationData`, which for `in_app_purchase_android` is the raw Google Play `purchaseToken` (confirmed by reading the `in_app_purchase_android` package source).

### `GET /api/v1/purchases/products`

Returns the backend's product catalog. **Used by the app** at service startup via `SubscriptionService._resolveProductIds()` → `SubscriptionBackendClient.fetchProductIds()`. The typed model lives in `subscription_product_catalog.dart`; `fetchProductCatalog()` is also available for callers that need the full payload. Requires `Authorization` in practice (see below).

Confirmed live response shape:

```json
{
  "status": "success",
  "data": {
    "ios": [
      {
        "product_id": "com.gys.powwow.year",
        "type": "subscription",
        "duration": "1 year"
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
        "product_id": "com.gys.powwow.one.time",
        "base_plan": null,
        "type": "non-consumable",
        "duration": "lifelong"
      }
    ]
  }
}
```

| Field | iOS | Android | Used by app today |
|---|---|---|---|
| `status` | yes | yes | yes — must be `success` for typed parse |
| `data.ios` / `data.android` | yes | yes | yes — platform-specific entry lists |
| `product_id` | yes | yes | yes — passed to `queryProductDetails()` |
| `type` | `subscription` / `non-consumable` | same | parsed, not yet used in UI |
| `duration` | e.g. `1 year`, `lifelong` | same | parsed, not yet used in UI |
| `base_plan` | — | `year`, `monthly`, `weekly`, or `null` | parsed, not yet used in UI |

Prices, titles, and currency are **not** in this API — they still come from App Store / Google Play after `queryProductDetails()`.

`fetchProductIds()` uses the typed catalog first and falls back to a legacy best-effort parser only for older/dev payload shapes. If the API returns an empty product set or throws, the service falls back to locally configured product IDs (`SubscriptionProductIds` constants or `--dart-define` overrides).

### `GET /health`

Plain healthcheck, no auth. Not used by the app.

### No `GET entitlement/me` (or equivalent)

There is no endpoint to ask "what is this user currently entitled to" outside of a purchase/restore event. See `docs/current-state.md` → Known Limitations for how the app works around this (local cache + `restorePurchases()`).

Client-side cache policy as of 2026-07-06:

- Successful validation responses are cached with `validatedAt` (taken from `validatedAt` / `validated_at` / `checkedAt` / `checked_at` when present, otherwise the client validation time).
- A cached entitlement with a precise future `expiresAt` can unlock the app until that expiry.
- A cached entitlement without `expiresAt` is treated as temporary only: 15 minutes in sandbox, 24 hours otherwise.
- If `restorePurchases()` completes without any replayed transactions and the current entitlement exists only because of cache and has no `expiresAt`, the app clears it and routes through the blocking subscription paywall.

## Validation response bodies

**Current truth:** validation success response schemas are not documented in the primary Postman collection. The live OpenAPI spec observed on 2026-07-02 also declared `responses.200.schema = {}` for validate endpoints. Real successful iOS sandbox validations were observed in device logs on 2026-07-06. The raw diagnostic body is still truncated by the generic log helper at 80 characters, but the compact `purchase_validation_response_fields` event confirmed the live success response's top-level keys.

Observed 2026-07-06 iOS sandbox flow (`to_fix_logs_6.txt`):

- Startup fetched `GET /api/v1/purchases/products` successfully (`statusCode=200`) and loaded 4 App Store product IDs: `com.gys.powwow.year`, `com.gys.powwow.month`, `com.gys.powwow.week`, `com.gys.powwow.life`.
- A manual Restore tapped on the paywall completed with `restore_purchases_completed_no_transactions`; no validation request was made for that restore.
- Buying/replaying `com.gys.powwow.week` produced `POST /api/v1/purchases/validate/ios/sandbox` requests with StoreKit transaction IDs such as `2000001200338982`, `2000001200341011`, and `2000001200351350`.
- A `200` success response had the visible raw prefix `{"status":"success","message":"Ios purchase validated successfully","product_...`.
- The compact field log for transaction `2000001200351350` reported exactly 3 top-level keys: `status`, `message`, and `product_id`; `product_id` was `com.gys.powwow.week`.
- No calls to `POST /api/v1/purchases/validate/ios/production` or `POST /api/v1/purchases/validate/android` appeared in these logs.
- The compact field log explicitly reported `hasActive=false`, `hasStore=false`, `hasEnvironment=false`, `hasWillRenew=false`, `hasValidatedAt=false`, `hasExpiresAt=false`, `hasExpiresDateMs=false`, `hasExpiryTimeMillis=false`, and `hasExpirationTimeMillis=false`.
- The parsed entitlement events still showed `active=true`, `environment=sandbox`, and client-visible `validatedAt`, but those are client fallback/inferred values: HTTP 200 means active, iOS JWS endpoint selection provides sandbox, and the client stamps `validatedAt` when the backend does not provide it.
- Because `SubscriptionEntitlement.fromValidationResponse()` falls back to the client validation time when the backend does not provide `validatedAt`, the `validatedAt` shown in `entitlement_gate_ready` should not be treated as a confirmed backend field unless a full raw response proves it.
- If the backend omitted an expiry field for the weekly subscription, the client cannot reliably know when access should end from backend data alone. The current client intentionally avoids granting permanent cache-only access in this case: sandbox cache-only entitlements without `expiresAt` expire after 15 minutes, and non-sandbox/unknown cache-only entitlements expire after 24 hours.

The Flutter client therefore uses best-effort parsing (`SubscriptionEntitlement.fromValidationResponse` in `subscription_entitlement.dart`) so it can work with likely backend shapes, but these fields should not be treated as confirmed backend contract until Postman is updated with real examples:

- **Validity**: checks `active` / `is_valid` / `valid` (booleans) or `status` (int/string, `0` = valid, matching classic App Store `verifyReceipt` status code conventions). If none of these are present, **HTTP 200 itself is treated as proof of validity** (the server already accepted the receipt/token).
- **Expiry date**: tries `expiresAt` (ISO-8601 or epoch ms), `expires_date_ms` (string or int ms — classic App Store field name/shape), `expiryTimeMillis` and `expiration_time_millis` (int ms — common Play Store field names), in that order.
- **Validation time**: tries `validatedAt` / `validated_at` / `checkedAt` / `checked_at`, otherwise uses the client-side validation time for cache TTL decisions.
- **Product ID**: tries `productId` / `product_id`, falling back to the product ID the client sent in the request.
- **Auto-renew**: tries `willRenew` / `will_renew` (bool) or `auto_renew_status` (0/1 int, or bool/string — classic App Store field).

Every successful response body is logged via `subscriptionDiagnosticFlow('purchase_validation_response', ...)` (visible in the in-app test logs screen and Crashlytics breadcrumbs), but the generic diagnostic formatter truncates long field values. The client therefore also logs `purchase_validation_response_fields`, which emits compact non-truncated top-level JSON keys plus presence/value fields for `active`, `productId`/`product_id`, `store`, `environment`, `validatedAt` variants, expiry variants, and `willRenew` variants. Use that event to confirm which fields are actually present; use a full raw capture before adding exact examples to Postman.

### Error responses (confirmed live)

- `401` with a fake/invalid token: `{"detail": "Invalid token"}`.
- `422` with a missing required field (FastAPI validation error): `{"detail": [{"loc": ["body", "receipt_data"], "msg": "Field required", ...}]}`.

`SubscriptionBackendClient` understands both shapes: a string `detail` is used as-is; a list `detail` has each item's `msg` joined with `; ` into a single readable message.

## Confirmed corrections applied to the repository Postman copy

- The original shared collection marked `GET /api/v1/purchases/products` as `"auth": {"type": "noauth"}`. Live testing showed this was wrong: an unauthenticated request returned `422 Field required` (missing `Authorization` header), and a request with a bogus token returned `401 Invalid token`. The repository Postman copy now keeps the `Authorization` header and no longer marks that item as `noauth`.
- The original shared collection had no example response for `GET /api/v1/purchases/products`. The repository Postman copy now includes the confirmed live `200` response shape for that endpoint.
- The collection's `base_url` variable in `docs/postman/` is set to the production URL and works out of the box; swap it to a local URL if you're running the validator yourself.

## Backend/Postman action items

1. Add real success response examples to Postman for:
   - `POST /api/v1/purchases/validate/ios/sandbox`
   - `POST /api/v1/purchases/validate/ios/production`
   - `POST /api/v1/purchases/validate/android` for subscriptions
   - `POST /api/v1/purchases/validate/android` for life-long purchases
2. Decide and document the exact validation response schema. Recommended minimum:
   - `active`: boolean
   - `expiresAt`: ISO-8601 UTC timestamp for subscriptions; `null` for life-long purchases
   - `validatedAt`: ISO-8601 UTC timestamp
   - `productId`: string
   - `store`: `app_store` / `play_store`
   - `environment`: `sandbox` / `production` for iOS where applicable
   - optional `willRenew`: boolean when the store exposes it
3. If the backend already returns any of those fields in practice, update the Postman collection with the actual full response body. Do not leave them documented only in markdown. The 2026-07-06 device logs prove that iOS sandbox validation returns `200` with a success body, but they are too truncated to use as the Postman example.
4. Add or confirm an entitlement read endpoint, preferably `GET /api/v1/purchases/entitlement/me`, returning the same `active`/`expiresAt` shape for the current Firebase user. Without this, the app can only infer current status from local cache plus `restorePurchases()` replay.
5. Keep `GET /api/v1/purchases/products` in Postman aligned with production behavior: it requires `Authorization` in practice, and its confirmed live response shape is now included as a Postman example.
