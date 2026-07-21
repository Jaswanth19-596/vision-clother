# Vision Clother Backend — Firebase Proxy

A thin passthrough proxy that holds the OpenRouter and Pexels API keys server-side, so distributed iOS builds (TestFlight/App Store) never ship a provider key. It does no business logic — see `docs/backend/architecture.md` and `docs/backend/conventions.md` at the repo root for the design rationale — with two deliberate exceptions that need Admin SDK privileges: `/account/delete` and `/iap/verify` (see `src/app.ts`'s doc comments).

Deployed as three separate Cloud Functions, split by cost/latency profile (`src/index.ts` — see `docs/backend/architecture.md`'s "Cloud Functions" table for the memory/timeout/maxInstances of each):

Routes, behind Firebase Auth (guest-first anonymous sessions; Google Sign-In or Phone Number to link):

- **`proxyApi`** (256MiB, 60s timeout — bumped from an initial 15s, which caused spurious 504s on the two LLM routes below)
  - `POST /openrouter/chat` → `https://openrouter.ai/api/v1/chat/completions`
  - `POST /openrouter/recommend` → same handler, quota-gated (`src/middleware/quota.ts`)
  - `GET /pexels/search` → `https://api.pexels.com/v1/search`
- **`heavyApi`** (512MiB, 180s timeout)
  - `POST /openrouter/tryon` → same handler as `/openrouter/chat`, quota-gated as `tryOn`
  - `POST /openrouter/images` → `https://openrouter.ai/api/v1/images` (quota-gated as `tryOn`)
- **`accountApi`** (256MiB, 30s timeout)
  - `POST /account/delete` → Admin-SDK account purge (`src/routes/accountDelete.ts`)
  - `POST /iap/verify` → StoreKit 2 purchase verification + credit grant (`src/routes/iapVerify.ts`): verifies the transaction JWS signature server-side, maps productId through `src/iap/products.ts`'s grant table, and atomically credits `users/{uid}/meta/usage`'s `purchased*Balance` fields with a `processedTransactions/{transactionId}` idempotency ledger. Env flag `IAP_ALLOW_XCODE_UNVERIFIED=true` (functions `.env`, default off — **never in production**) accepts unverifiable Xcode-signed transactions for local `.storekit` testing; production-environment transactions are rejected until an App Store Connect `appAppleId` is wired into `src/iap/verifyTransaction.ts`.
  - `GET /entitlement/limits`, `GET /analytics/config` → server-resolved config reads

App Check and Sign in with Apple are both deferred — both need a paid Apple Developer account to configure (App Attest requires it for the App ID capability; Sign in with Apple requires it for the capability itself). See `docs/decisions/resolved-v1.md`.

## One-time setup

Project `visionclother` (number `1008598090428`) is already wired up — most of this was done via `npx -y firebase-tools@latest` rather than the console:

1. ~~Create project~~ / ~~register iOS app~~ / ~~fetch `GoogleService-Info.plist`~~ — done (`apps:create IOS`, `apps:sdkconfig IOS`, saved to `Vision_clother/Vision_clother/Config/GoogleService-Info.plist`, safe to commit — it's not a secret, unlike `Secrets.plist`).
2. ~~Firestore~~ — Standard-edition default database provisioned (used only for the rate-limit counter — no wardrobe data goes here), security rules deny all client access (`backend/firestore.rules`) since only the Admin SDK touches it.
3. ~~Google Sign-In~~ — enabled via `firebase.json`'s `auth` block + `firebase deploy --only auth` (config-as-code, no console click needed).
4. **Phone Number sign-in — one manual step, not CLI-automatable**: Firebase Console → your project → Authentication → Sign-in method → **Phone** → Enable. (Only anonymous/email-password/Google are scriptable via `firebase.json`'s `auth` block today.)
5. If you fork this to a different Firebase project: replace `visionclother` in `.firebaserc`, re-run the `apps:create`/`apps:sdkconfig` steps for your own bundle ID, and repeat steps 2–4.

No APNs auth key is configured (also paid-account-gated), so Phone Auth always falls back to Firebase's reCAPTCHA-in-Safari verification rather than silent push — this is expected, not a bug. If you test with a real phone number, note SMS may take a few seconds; for repeatable testing without a live device, register a test number in Console → Authentication → Sign-in method → Phone → Phone numbers for testing.

## Install & authenticate the CLI

```bash
npm install -g firebase-tools   # if not already installed
firebase login
```

## Local development (Firebase Emulator Suite)

```bash
cd backend/functions
npm install
npm run serve   # builds + starts the functions/auth/firestore emulators
```

This calls the **real** OpenRouter/Pexels APIs (no emulator exists for third-party HTTP APIs) but emulates Auth/App Check/Firestore locally. Set secrets for the emulator via a local `.secret.local` file (gitignored) or export them as env vars before starting — see [Firebase's local secret docs](https://firebase.google.com/docs/functions/config-env#secret-manager). Point the iOS app's `Config/ProxyConfig.swift` base URLs at `http://localhost:5001/<project-id>/us-central1/<proxyApi|heavyApi|accountApi>` during local testing.

## Deploying

Three separate Cloud Functions are deployed from this one codebase — `proxyApi`, `heavyApi`, `accountApi` (`src/index.ts`), split by cost/latency profile (see `docs/backend/architecture.md`'s "Cloud Functions" table for memory/timeout/maxInstances per function):

```bash
firebase functions:secrets:set OPENROUTER_API_KEY
firebase functions:secrets:set PEXELS_API_KEY
cd backend && firebase deploy --only functions
```

After deploy, the CLI output (also visible in the Firebase console) prints **three** HTTPS URLs, one per function. Update all three base URLs in `Config/ProxyConfig.swift` (`proxyBaseURL`, `heavyBaseURL`, `accountBaseURL`) to match — there is no longer a single shared base URL.

**Migrating from the old single `api` function:** if a previous `api` function is still deployed, deploy the new three first, update `ProxyConfig.swift`, verify traffic against the new URLs, then run `firebase deploy --only functions` again (or `firebase functions:delete api`) to remove the now-unused `api` function — leaving it running only wastes idle-instance cost, since traffic will have moved off it.

## Testing

```bash
cd backend/functions
npm test
```

Vitest unit tests cover: Auth middleware rejection paths (missing/invalid token), the rate-limit boundary, and each route's request-forwarding + upstream-error-passthrough behavior. No live network calls are made in tests — `fetch` and `firebase-admin` are mocked.
