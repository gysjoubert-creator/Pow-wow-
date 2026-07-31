# PowWow Current State

This document captures the current engineering state of the PowWow project as reflected in the repository on May 19, 2026. It is intended as a factual snapshot of what exists today, including gaps and unstable areas.

## Project Overview

PowWow is a Flutter mobile app focused on tribe-based audio communication. The current product shape combines:

- anonymous sign-in and lightweight profile creation,
- tribe membership driven by a `tribeId`,
- invite sharing through deep links,
- incoming call notifications,
- audio room participation via LiveKit,
- a two-tab main experience for live conversation and member visibility.

## Tech Stack

- Flutter with Dart 3.11
- GetX for routing, controller lifecycle, and dependency lookup
- Firebase Core, Auth, Firestore, Storage, Messaging, and Crashlytics
- LiveKit for audio room connectivity and tribe presence heartbeats (`powwow.presence` data packets)
- `flutter_webrtc` as a direct dependency for iOS `AVAudioSession` configuration in `LiveKitController`
- `app_links` for deep-link handling
- `share_plus` for invite sharing
- `flutter_callkit_incoming` for incoming call UI
- `flutter_foreground_task` for Android foreground service handling during active audio sessions
- `get_storage` and `shared_preferences` for local persistence used by logs/settings/subscription entitlement cache
- `in_app_purchase` and `in_app_purchase_android` for store purchases, validated against an external "receipt-validator" HTTP API (see [In-app purchases / subscriptions](#in-app-purchases--subscriptions))

## Current User Flows

### App bootstrap

- On the first launch, the app opens a three-page onboarding flow before bootstrap: family connection, tribe invites, and the hold-to-speak gesture. **Skip** and **Start PowWow** persist a versioned completion flag in `get_storage`, so later launches go directly to `SplashScreen`.
- `lib/main.dart` initializes Flutter bindings, locks portrait mode, starts log capture, initializes Firebase, registers fatal/async error reporting to Crashlytics, and registers `AuthService`.
- `SplashScreen` signs the user in anonymously when needed, syncs a pending FCM/VoIP token if one was received before auth was ready, then loads the current user profile from Firestore.
- If Firebase Auth loses the persisted session (seen on some Android devices), `SplashScreen` migrates the Firestore profile from `lastKnownUid` to the new auth uid while **keeping the existing `tribeId`** so shared tribe membership is not broken.
- If bootstrap fails (for example first launch without network during anonymous sign-in), `SplashScreen` shows a user-facing error message and an inline **Try again** action via shared `RetryErrorView` (`lib/widgets/retry_error_view.dart`) instead of staying on an endless spinner or surfacing raw Firebase exception text.
- The same `RetryErrorView` is reused for blocking errors on `CreateProfileScreen` (compact layout above the form) and for recoverable tribe/audio failures on `HomeScreen` (compact banner with retry that restarts the Firestore members listener and re-evaluates LiveKit auto-connect).
- Users without a Firestore profile are sent to profile creation. Users with a profile are sent to the dashboard only when `SubscriptionService` has an active entitlement; otherwise they are sent to the subscription paywall.

### Profile creation

- `CreateProfileScreen` collects a username and optional avatar image.
- Avatar images are cropped to a centered square and uploaded to Firebase Storage.
- A `UserProfile` document is then created in Firestore, defaulting the initial `tribeId` to the current user id.
- After profile creation, the same subscription gate is applied: active entitlement opens the dashboard; missing entitlement opens the paywall.

### Main app navigation

- For subscribed users, the dashboard exposes two tabs: `Home` and `Family`.
- Routing is defined through GetX pages in `lib/app/routes/`.
- There is a commented-out `calling` route, but no active calling screen route is currently wired in.

### Tribe participation and audio

- `HomeController` owns the main tribe state: current profile, tribe member list, Firestore member listener, invite link listener, and `LiveKitController`.
- Tribe membership is derived from Firestore users with the same `tribeId`.
- The last server-confirmed tribe member list is cached locally by `TribeMembersCacheStorage` in `get_storage`, scoped by both the signed-in owner uid and `tribeId`. `HomeController` hydrates that snapshot as soon as it is created, so returning users can see the tribe before Firebase and LiveKit startup work finishes. Presence/call status is deliberately not persisted.
- The Firestore listener starts immediately and includes metadata updates. Firestore-local and explicit-cache snapshots are display-only: calls, removal, and leaving the tribe remain disabled until a server snapshot confirms the current membership. A server snapshot replaces the visible list, refreshes the explicit cache, and only then schedules LiveKit auto-connect independently, so a slow voice-room join no longer blocks member rendering.
- `HomeScreen` shows the current tribe, active member count, hold-to-speak control, and last-message card support.
- Outgoing call requests are triggered through the app backend API and surfaced through UI actions on member rows.
- `LiveKitController` connects to a hosted LiveKit instance, requests microphone and Bluetooth permissions, and toggles the local microphone for push-to-talk style interaction.
- Remote member presence in the UI (`CallMemberStatus.listening` / `silent`) uses app-level soft presence on top of LiveKit room membership. While connected, each client publishes an unreliable LiveKit data packet every 2 seconds on topic `powwow.presence`; receivers track `lastSeen` per remote identity. `LiveKitController.getStatus()` marks a remote participant `listening` when the latest heartbeat is within 5 seconds, or during a 5-second grace window right after `ParticipantConnectedEvent` before the first heartbeat arrives; otherwise `silent`. A 1-second timer compares presence snapshots and triggers UI refresh when displayed status changes. LiveKit may still keep the participant in `remoteParticipants` for roughly 15–20 seconds after a kill or network loss; `ParticipantDisconnectedEvent` remains the source of truth for final cleanup. Policy constants and pure status logic live in `lib/screens/tabs/home/powwow_presence.dart` (`test/powwow_presence_test.dart`). Clients without this heartbeat still appear `listening` until LiveKit removes them; updated clients can show `silent` for those peers sooner because no heartbeats arrive.
- If LiveKit reaches a terminal unexpected disconnected state after SDK reconnect attempts are exhausted, `HomeController` can perform a bounded app-level recovery with a fresh token while the tribe still has active room conditions. Intentional disconnects, duplicate identity, participant removal, and room deletion are not retried. Recovery backoff is lifecycle-aware (`lib/screens/tabs/home/livekit_recovery_policy.dart`): while the app is in the foreground (`resumed`), auto-retry uses shorter delays (`0s → 5s → 10s → 15s`, 4 attempts, ~30s of pauses) plus a 30-second wall-clock cap; in background/inactive states it keeps the longer backoff (`0s → 5s → 15s → 30s → 60s`, 5 attempts). Background recovery failures do not surface error banners; when the user returns to the app, `HomeController` clears stale recovery state and starts a fresh auto-connect without showing errors from the background period. Exhausted-recovery banners are shown only in foreground when no join is already in progress. When a LiveKit join fails (timeout, ICE failure, duplicate-identity collision after a long background), `HomeScreen` shows a `RetryErrorView` banner (`Voice room connection failed` + **Try again**). Manual retry force-disconnects any stuck/zombie join (`retry_force_disconnect` → `disconnect_completed`), resets the `CallSessionCoordinator`, resets the recovery counter, and restarts the tribe listener plus LiveKit auto-connect evaluation. Auto-join, manual retry, and app-level recovery connection attempts now mark the coordinator phase/origin before token fetch/LiveKit connect, while existing `connected()`/`failed()` terminal updates preserve that origin. This ensures **Try again** always starts a clean new connection rather than hitting `connect_livekit_skipped_busy`.
- On iOS, `LiveKitController` uses a listen-only `playback` audio session with `mixWithOthers` so PowWow room audio can continue alongside audio from other apps without lowering their volume at baseline. When a remote LiveKit participant is actively speaking, it temporarily adds `duckOthers`; when the local mic is enabled for PTT it switches to `playAndRecord`, stops mic capture again on mute, then returns to the listen-only session.
- While the app is in background, PowWow plays a very quiet local-only white-noise asset through `just_audio` to keep the iOS AVAudioSession active. This prevents iOS from blocking `RTCPeerConnection addTransceiver` calls when LiveKit performs a full reconnect after a network interruption. The noise is connection-agnostic: it plays regardless of LiveKit room state, is never published as a LiveKit track, stops in foreground, stops when the local mic is enabled, stops when a remote participant is actively speaking, and resumes immediately once the room is silent again in background (no delayed timer, because iOS may not fire Dart timers while suspended).
- Manual iOS background audio regression scenarios live in [`docs/audio-background-regression.md`](audio-background-regression.md).

### Incoming call handling

- Firebase Messaging background handling is implemented in `main.dart`.
- Incoming messages with type `INCOMING_CALL` are surfaced through `flutter_callkit_incoming`: iOS uses CallKit-backed incoming call UI, while Android uses the plugin's Android incoming-call flow.
- iOS and Android token handling are split between VoIP and FCM flows.
- On iOS, incoming-call state is synchronized from native CallKit via `activeCalls()` as well as Flutter CallKit events.
- `CallSessionCoordinator` is the single source of truth for call-session state. It stores the current phase plus call context (`origin`, CallKit call id, accepted-call mic preference, CallKit audio-session activity, foreground-decline suppression, and cleanup status), tracks non-incoming connection phases (`autoJoin`, `manualRetry`, `recovery`), and bridges timing between app startup, CallKit `Accept`, native `activeCalls()` recovery, and `HomeController` initialization.
- Coordinator getters such as `shouldBlockTribeAutoConnect` and `shouldSkipZombieDisconnectOnResume` block premature tribe auto-join and zombie disconnects without relying on mutable global compatibility flags.
- On iOS, accepting a call can now start the LiveKit join path before `AppLifecycleState.resumed` if the app is still behind the native CallKit screen.
- While the user remains on the native iOS CallKit screen after `Accept`, the initial LiveKit microphone state is brought up enabled so the system mute button matches the real published mic track.
- On iOS, LiveKit automatic speaker routing is disabled; PowWow applies receiver/earpiece once when a CallKit call is accepted (so the native UI does not start in speakerphone), then leaves the CallKit Speaker button under user control.
- After foreground recovery on iOS, the app attempts to mark the accepted CallKit call as connected and then dismiss the CallKit call record.
- Android additionally requests notification permission, requests full-intent support, declares vibration capability for incoming-call alerts, and uses a foreground service while an audio room is active.

### Invite and deep-link flow

- Invite sharing is handled by `InviteLinkService`, which builds a shareable URL based on the current `tribeId`.
- The current invite base URL points to a GitHub Pages-hosted landing page.
- `app_links` is used to read both the initial launch link and ongoing deep links while the app is running.
- When a valid `roomId` arrives through a link, the local profile is updated to the new `tribeId` and the Firestore tribe listener is restarted.

### Tribe settings and local preferences

- `TribeSettingsScreen` exposes profile display, invite access, and local audio preferences.
- Users in another member's tribe (`tribeId != uid`) can leave via **Leave Tribe** in the profile section. Confirmation resets `tribeId` to the current user's `uid`, disconnects LiveKit, and restarts the Firestore members listener through `HomeController.leaveTribe()`.
- `SettingsStorage` persists intercom volume, headphone priority, and bedtime DND values through `SharedPreferences`.
- The settings screen also displays the current app version/build using `package_info_plus`.

### In-app purchases / subscriptions

- Stack: `in_app_purchase` (store front-end) + `in_app_purchase_android` (Play-specific offer/base-plan details), backed by a standalone "receipt-validator" HTTP API. There is no in-house purchases backend; the app talks directly to `https://receipt-validator-237694335752.us-central1.run.app` (overridable via `--dart-define=POWWOW_IAP_API_BASE_URL`). Full contract details, known gaps, and Postman collection: [`docs/iap-purchases-api.md`](iap-purchases-api.md).
- Code lives under `lib/app/services/subscriptions/`:
  - `subscription_product_ids.dart` — store constants used for Android validation metadata and store-specific labeling. These constants are not used as the paywall product-catalog fallback.
  - `subscription_store_gateway.dart` — thin wrapper around `InAppPurchase` (query products, buy, restore, complete purchase).
  - `subscription_store_gateway.dart` — thin wrapper around `InAppPurchase` (query products, buy, restore, complete purchase). On iOS it also asks a small StoreKit 2 method channel for each product's `Product.isFamilyShareable` flag and logs it with the loaded product diagnostics.
  - `subscription_backend_client.dart` — `SubscriptionBackendClient.fetchProductIds()` reads store product IDs from `/api/v1/purchases/products`; `verifyPurchase()` posts the receipt/token to `/api/v1/purchases/validate/ios` or `/validate/android` with a Firebase ID token in `Authorization`, and best-effort-parses the response into a `SubscriptionEntitlement`.
  - `subscription_entitlement.dart` — `SubscriptionEntitlement.fromValidationResponse()` tolerates several plausible key names for active/expiry/renewal/source fields because the primary Postman contract does not document validation success responses; HTTP 200 with no explicit invalidity signal is treated as active and stamped with `validatedAt`. Family-shared entitlements are recognized when the validator response includes `source`/`ownershipType`/`in_app_ownership_type`-style fields.
  - `subscription_entitlement_storage.dart` — `SubscriptionEntitlementStorage` caches the last confirmed entitlement in `get_storage`, keyed per Firebase uid (or an anonymous key when no user is signed in).
  - `subscription_service.dart` — `SubscriptionService` (GetX service) owns purchase/restore flow state, hydrates `entitlement` from the local cache on `initialize()` (before any network call, for a flicker-free UI), and re-validates purchases whenever the store replays them.
  - `entitlement_gate.dart` and `lib/screens/subscription/` — UI/gating built on top of `SubscriptionService.state`.
- Subscription enforcement is app-level: after bootstrap/profile creation, the dashboard is only opened for users with an active entitlement. Users without entitlement see `SubscriptionScreen` as a blocking paywall, and `DashboardController` redirects back to the paywall if the dashboard route is reached without access.
- Paywall products are loaded from the backend catalog API. If the backend catalog is unavailable, empty, or not configured, `SubscriptionService` does not fall back to local product IDs and leaves purchases unavailable.
- Purchase flow: `buyProduct()` starts a store purchase; store purchase-stream updates flow through `_handlePurchaseUpdates` → `_verifyPurchase`, which posts to the validator, completes the store purchase, and caches the resulting entitlement.
- StoreKit restore/replay bursts are debounced briefly and collapsed to the newest transaction per product before validation, so sandbox renewal history does not fan out into many duplicate backend calls during app startup.
- Refresh flow: there is no `GET entitlement/me` endpoint on the backend, so `refreshEntitlement()` (called on `initialize()`, auth user change, pull-to-refresh, and the "Restore purchases" button) simply calls the store's `restorePurchases()`; any purchases it replays flow through the same verify/cache path above. Cached entitlements with a precise future `expiresAt` can unlock the app until that expiry. Cached entitlements without `expiresAt` require a recent `validatedAt` (15 minutes for sandbox, 24 hours otherwise), and are cleared if `restorePurchases()` completes with no replayed transactions.

## Architecture Snapshot

### Entry point and app lifecycle

- `lib/main.dart` contains the highest concentration of bootstrap, push, and CallKit lifecycle logic, including the state machine that recovers accepted incoming calls across startup and foreground transitions.
- `CallSessionCoordinator` owns production incoming-call behavior that used to be represented by global flags. `main.dart`, `HomeController`, and `LiveKitController` read coordinator getters/snapshots for timing-sensitive state between app startup, CallKit actions, `activeCalls()` recovery, and `HomeController` initialization.

### UI layers

- `lib/screens/` contains feature screens grouped by flow (`splash`, `create_profile`, `dashboard`, `tribe_settings`, `tabs/home`, `tabs/family`).
- `lib/widgets/` contains shared UI pieces such as loading and avatar placeholders.
- `lib/app/theme.dart` centralizes colors and text styles used across the app.

### State and controllers

- Controllers are GetX-based and generally colocated with their screens.
- `DashboardController` manages tab state.
- `HomeController` is the main coordination layer for app behavior and participates directly in the incoming-call join flow by delaying auto-connect while an iOS call is still ringing and by applying the accepted-call mic/connect mode chosen in `main.dart`.
- `TribeSettingsController` manages persisted settings and version info.
- `TestLogsScreenController` supports an internal debug/log screen rather than automated tests.

### Services

- Firebase service classes cover auth, Firestore profile/token access, and avatar storage upload.
- `TribeMembersCacheStorage` owns the versioned, owner-and-tribe-scoped local member snapshot. `FirestoreService.watchMemberSnapshots()` exposes member data together with Firestore cache/server metadata so controllers can keep cached data visually useful without treating it as authoritative.
- Firestore push token documents are merged by user id and include platform metadata; iOS VoIP token records include the APNs VoIP topic `com.gys.powwow.voip` and push environment for the backend call service.
- `ApiService` wraps backend HTTP calls for LiveKit token acquisition and outgoing call requests. LiveKit JWTs from the token service must include `can_publish_data: true` so presence heartbeats can use `publishData` (see comment on `fetchLiveKitToken`).
- `InviteLinkService` encapsulates link creation, sharing, and inbound link parsing.

### Data models

- `UserProfile`, `TribeMember`, and `TribeMessage` represent the main app-level entities. `TribeMembersSnapshot` carries a member list plus its Firestore cache/server origin.
- `TribeMemberStatus` is modeled as an enum used to drive presence/status UI.

## Platform Notes

- Android and iOS project shells are both present under `android/` and `ios/`.
- Android-specific runtime behavior includes notification permission prompts, full-intent permission request, incoming-call vibration via the CallKit notification/full-screen flow, and foreground service activation for active audio sessions.
- iOS-specific behavior includes VoIP token retrieval and CallKit integration settings.
- Current iOS incoming-call behavior:
  - a ringing CallKit call blocks Firestore-driven auto-join,
  - an accepted call is recovered from native CallKit state even when Flutter did not receive the original `Accept` event,
  - if `Accept` happens while the app is still behind the native CallKit UI, LiveKit connect can begin before the app fully foregrounds,
  - the accepted call can start with mic enabled while CallKit remains on-screen, avoiding the previous "mute/unmute once to be heard" failure mode,
  - after the app foregrounds, PowWow marks the CallKit call connected and then clears the native call record.
- The app is locked to portrait orientation in `main.dart`.
- Voice-related permission requests are scattered across startup, `HomeController`, and `LiveKitController`, so permission handling is functional but not yet centralized.

## Current Quality And Status

- The previous root `README.md` was effectively a placeholder and did not describe the actual project.
- `flutter analyze` currently reports 3 issues in the checked-in codebase.
- Reported dependency declaration issues indicate imported packages that are not listed in `pubspec.yaml`:
  - `http`
  - `shared_preferences`
- Additional analyzer findings include an unnecessary multiple-underscore pattern in `lib/screens/tabs/home/widgets/hold_to_speak_button.dart`.
- The repository has a standard top-level `test/` directory with automated unit tests. `BackgroundWhiteNoiseCoordinator` is covered by a dedicated suite in `test/background_white_noise_service_test.dart`. LiveKit soft-presence policy is covered in `test/powwow_presence_test.dart`.
- Internal debugging utilities (log screen, test helpers) live separately in `lib/test/` and are not part of the Flutter test suite.
- The codebase contains several `td`, `check`, and `del after test` markers that suggest active iteration and incomplete cleanup.

## Known Limitations And Risks

- Documentation maturity is low; this document is the first real project status snapshot in the repository.
- Runtime configuration is partially hardcoded:
  - backend URLs are embedded directly in service classes,
  - the LiveKit URL is embedded in `LiveKitController`,
  - invite base URLs are embedded in `InviteLinkService`.
- Incoming-call and room-join behavior still has lifecycle-heavy branches in `main.dart`, but call-session state now flows through `CallSessionCoordinator` instead of mutable global flags.
- iOS incoming-call acceptance from a killed app is now working in the recently verified locked-screen and unlocked-screen accept flows, but the implementation remains lifecycle-heavy and should still be treated as regression-prone.
- Accepted iOS calls can begin LiveKit connection and microphone publication while the app UI is not yet foregrounded, by design, in order to keep the native CallKit experience functional.
- Native `AppDelegate` and `SceneDelegate` behavior remains part of the production iOS incoming-call path, even though the most recent accept/audio regressions were addressed.
- Test coverage is minimal from a conventional Flutter perspective.
- There are user-visible debug affordances in the app, including access to the internal test logs screen from the home header.
- The repository currently has in-progress local edits in some Home/Family feature files, so the working tree may not always represent a stable release point.
- The receipt-validator backend has no `GET entitlement/me` endpoint, so the app's notion of "current subscription status" is always either a locally cached last-known-good result or the outcome of replaying store purchases via `restorePurchases()` — there is no way to ask the backend "what is this user entitled to right now" without a fresh purchase/restore event. The client now limits cache-only entitlements without `expiresAt`, but the correct long-term fix is a backend response or endpoint that returns exact `active` and `expiresAt`.
- The validator's success response schema is undocumented in the primary Postman collection (`"response": []` for validate endpoints), and the live OpenAPI spec observed on 2026-07-02 declared an empty `{}` schema. Live iOS sandbox purchase logs from 2026-07-06 confirmed `POST /api/v1/purchases/validate/ios/sandbox` returns `200` with a success body whose compact field log has only `status`, `message`, and `product_id` at the top level. The backend response did not include client-visible `active`, `expiresAt`, `validatedAt`, `store`, `environment`, or `willRenew`; active/sandbox/validatedAt in client entitlement logs are fallback or inferred values. `SubscriptionEntitlement.fromValidationResponse()` is intentionally best-effort client tolerance, not a confirmed backend contract: it tries several plausible field names and otherwise treats HTTP 200 as proof of a valid receipt/token. This should be tightened only after full real response bodies are captured and added to Postman, ideally with explicit `active`, `expiresAt`, and `validatedAt`.
- `in_app_purchase_storekit` defaults to StoreKit 2, whose `serverVerificationData` is a per-transaction JWS, not the classic whole-receipt base64 string the validator's `receipt_data` field name implies. The app sends the JWS as-is (documented in [`docs/iap-purchases-api.md`](iap-purchases-api.md)); this needs to be reconciled with the backend team once real purchase logs are available.

## Practical Entry Points For Engineers

- Start with `lib/main.dart` for startup, push, and CallKit behavior.
- Read `lib/screens/tabs/home/home_controller.dart` next for the core tribe/audio flow.
- Use `lib/app/services/` to understand backend, Firebase, and deep-link integrations.
