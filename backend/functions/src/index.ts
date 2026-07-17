import { initializeApp } from "firebase-admin/app";
import { onRequest } from "firebase-functions/v2/https";
import { buildApp } from "./app";
import { openRouterApiKey, pexelsApiKey } from "./secrets";

initializeApp();

/**
 * Single HTTPS function serving all three passthrough routes
 * (/openrouter/chat, /openrouter/images, /pexels/search). One deployment,
 * one timeout/secrets config — see backend/README.md for the deployed
 * base URL to configure in the iOS app.
 */
export const api = onRequest(
  {
    secrets: [openRouterApiKey, pexelsApiKey],
    timeoutSeconds: 180,
    memory: "256MiB",
    // Public at the Cloud Run/IAM layer — the app's own auth gate is
    // `middleware/verifyAuth.ts` (Firebase ID token bearer), not IAM.
    // Without this, Cloud Run rejects every request with a 403 before it
    // ever reaches Express, regardless of a valid ID token.
    invoker: "public",
  },
  buildApp()
);
