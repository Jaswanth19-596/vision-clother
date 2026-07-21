import { initializeApp } from "firebase-admin/app";
import { onRequest } from "firebase-functions/v2/https";
import { buildProxyApp, buildHeavyApp, buildAccountApp } from "./app";
import { openRouterApiKey, pexelsApiKey } from "./secrets";

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
 * `/pexels/search`) — low memory, short timeout, high instance ceiling for
 * fan-out. Binds both provider secrets since all three routes need one or
 * the other.
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
    memory: "256MiB",
    maxInstances: 30,
    invoker: "public",
  },
  buildProxyApp()
);

/**
 * Real-generation-cost image routes (`/openrouter/images`,
 * `/openrouter/tryon`) — higher memory and a long timeout for slow
 * upstream image generation, capped at a lower instance ceiling since each
 * instance is costlier and this traffic is inherently lower-volume than
 * the passthrough routes.
 */
export const heavyApi = onRequest(
  {
    secrets: [openRouterApiKey],
    timeoutSeconds: 180,
    memory: "512MiB",
    maxInstances: 10,
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
 */
export const accountApi = onRequest(
  {
    timeoutSeconds: 30,
    memory: "256MiB",
    maxInstances: 20,
    invoker: "public",
  },
  buildAccountApp()
);
