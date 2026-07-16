# Vision Clother Backend — Firebase Proxy

A thin passthrough proxy that holds the OpenRouter and Pexels API keys server-side, so distributed iOS builds (TestFlight/App Store) never ship a provider key. It does no business logic — see `docs/backend/architecture.md` and `docs/backend/conventions.md` at the repo root for the design rationale.

Three routes, behind Firebase Auth (Google Sign-In or Phone Number):

- `POST /openrouter/chat` → `https://openrouter.ai/api/v1/chat/completions`
- `POST /openrouter/images` → `https://openrouter.ai/api/v1/images`
- `GET /pexels/search` → `https://api.pexels.com/v1/search`

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

This calls the **real** OpenRouter/Pexels APIs (no emulator exists for third-party HTTP APIs) but emulates Auth/App Check/Firestore locally. Set secrets for the emulator via a local `.secret.local` file (gitignored) or export them as env vars before starting — see [Firebase's local secret docs](https://firebase.google.com/docs/functions/config-env#secret-manager). Point the iOS app's proxy base URL at `http://localhost:5001/<project-id>/us-central1/api` during local testing.

## Deploying

```bash
firebase functions:secrets:set OPENROUTER_API_KEY
firebase functions:secrets:set PEXELS_API_KEY
cd backend && firebase deploy --only functions
```

After deploy, the function's HTTPS URL (shown in the CLI output, also visible in the Firebase console) is what the iOS app's `ProxyConfig.baseURL` should point to for release builds.

## Testing

```bash
cd backend/functions
npm test
```

Vitest unit tests cover: Auth middleware rejection paths (missing/invalid token), the rate-limit boundary, and each route's request-forwarding + upstream-error-passthrough behavior. No live network calls are made in tests — `fetch` and `firebase-admin` are mocked.
