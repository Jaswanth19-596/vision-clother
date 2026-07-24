import { initializeApp } from "firebase-admin/app";
import { onRequest } from "firebase-functions/v2/https";
import { onObjectFinalized } from "firebase-functions/v2/storage";
import { buildProxyApp, buildHeavyApp, buildAccountApp } from "./app";
import { openRouterApiKey, pexelsApiKey } from "./secrets";
import { scalingConfig } from "./config/scaling";
import { handleWardrobeImageFinalized } from "./triggers/wardrobeImageProcessing";

initializeApp();

/**
 * Split from the single `api` function into three, grouped by cost/latency
 * profile — see backend/README.md for the deployed base URLs to configure
 * in the iOS app (`Config/ProxyConfig.swift`) and
 * docs/backend/architecture.md's "Cloud Functions" section for the full
 * rationale. All three are `invoker: "public"` for the same reason the
 * original single function was — the app's own auth gate is
 * `middleware/verifyAuth.ts` (Firebase ID token bearer), not IAM; without
 * this, Cloud Run rejects every request with a 403 before it ever reaches
 * Express, regardless of a valid ID token.
 */

/**
 * Cheap passthrough routes only (`/openrouter/chat`, `/openrouter/recommend`,
 * `/pexels/search`). CPU/memory/concurrency/instance limits come from
 * `config/scaling.ts`'s `scalingConfig.proxyApi` — currently early-dev
 * defaults sized for ~10 active users, not the documented production
 * target; bump capacity there, not here.
 */
export const proxyApi = onRequest(
  {
    secrets: [openRouterApiKey, pexelsApiKey],
    // 60s, not the original 15s — /openrouter/chat and /openrouter/recommend
    // are real LLM completion calls (up to ModelConfig.maxTokens, plus a
    // possible fallback-model retry) that routinely exceed 15s; 15s caused
    // spurious 504s in practice. /pexels/search is fast and unaffected by
    // the larger ceiling.
    timeoutSeconds: 60,
    ...scalingConfig.proxyApi,
    invoker: "public",
  },
  buildProxyApp()
);

/**
 * Real-generation-cost image routes (`/openrouter/images`,
 * `/openrouter/tryon`) — long timeout for slow upstream image generation.
 * CPU/memory/concurrency/instance limits come from `config/scaling.ts`'s
 * `scalingConfig.heavyApi` — currently early-dev defaults sized for ~10
 * active users; bump capacity there, not here.
 */
export const heavyApi = onRequest(
  {
    secrets: [openRouterApiKey],
    timeoutSeconds: 180,
    ...scalingConfig.heavyApi,
    invoker: "public",
  },
  buildHeavyApp()
);

/**
 * Payments/account-management routes (`/account/delete`, `/iap/verify`,
 * `/entitlement/limits`, `/analytics/config`) — isolated so a provider
 * outage or quota spike on proxyApi/heavyApi can never starve account
 * deletion, purchase verification, or config reads. None of these routes
 * call OpenRouter/Pexels, so no provider secrets are bound here.
 * CPU/memory/concurrency/instance limits come from `config/scaling.ts`'s
 * `scalingConfig.accountApi` — currently early-dev defaults sized for ~10
 * active users; bump capacity there, not here.
 */
export const accountApi = onRequest(
  {
    timeoutSeconds: 30,
    ...scalingConfig.accountApi,
    invoker: "public",
  },
  buildAccountApp()
);

/**
 * Storage-triggered, not HTTP — fires on every finalized object in the
 * default bucket; `handleWardrobeImageFinalized` filters to
 * users/{uid}/wardrobeImages/{fileName} internally and no-ops on
 * everything else, including its own thumbnail/normalize writes (see
 * that file's self-trigger-loop guard). `region` MUST match the default
 * Storage bucket's region or the trigger silently fails to bind (Cloud
 * Functions v2 Storage-trigger requirement) — this codebase pins no
 * region anywhere else today, so us-central1 is the assumed project
 * default; verify against the actual bucket region (Firebase Console →
 * Storage, or `gcloud storage buckets describe`) before the first real
 * deploy and update this literal if it differs.
 */
export const wardrobeImageProcessing = onObjectFinalized(
  {
    region: "us-central1",
    ...scalingConfig.wardrobeImageProcessing,
  },
  handleWardrobeImageFinalized
);
