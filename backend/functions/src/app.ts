import express from "express";
import type { Express, NextFunction, Response } from "express";
import { verifyAuth } from "./middleware/verifyAuth";
import { rateLimitOnly } from "./middleware/governance";
import { creditGate } from "./middleware/creditGate";
import { responseCache } from "./middleware/responseCache";
import { idempotencyGate } from "./middleware/idempotency";
import { openrouterChatRouter } from "./routes/openrouterChat";
import { openrouterImagesRouter } from "./routes/openrouterImages";
import { pexelsSearchRouter } from "./routes/pexelsSearch";
import { accountDeleteRouter } from "./routes/accountDelete";
import { iapVerifyRouter } from "./routes/iapVerify";
import { entitlementLimitsRouter } from "./routes/entitlementLimits";
import { analyticsConfigRouter } from "./routes/analyticsConfig";
import { logEvent } from "./logger";
import type { AuthedRequest } from "./types";

/**
 * Mints (or adopts the client's) `X-Request-Id` before anything else runs,
 * logs the inbound request, and echoes the id back as a response header so
 * the iOS-side `AppLog` line for this same call (see
 * `Services/ProxyAuthHeaders.swift`) and this Cloud Logging line can be
 * grepped together by one short id. Logs the outcome (status + duration) on
 * `res.finish` so every request — including ones that error out downstream —
 * gets exactly one start line and one end line.
 */
function requestLogger(req: AuthedRequest, res: Response, next: NextFunction): void {
  const requestId = req.header("X-Request-Id") || Math.random().toString(36).slice(2, 10);
  req.requestId = requestId;
  res.setHeader("X-Request-Id", requestId);

  const start = Date.now();
  logEvent("info", "request.start", { requestId, method: req.method, path: req.path });
  res.on("finish", () => {
    logEvent("info", "request.finish", {
      requestId,
      method: req.method,
      path: req.path,
      status: res.statusCode,
      durationMs: Date.now() - start,
      uid: req.uid,
    });
  });
  next();
}

/**
 * Shared pipeline for all three split deployments (`proxyApi`/`heavyApi`/
 * `accountApi` in `index.ts`): mint/echo `X-Request-Id` + start/finish log
 * lines, then Firebase Auth verification. Splitting into three Cloud
 * Functions only changes which routes (and which
 * memory/timeout/maxInstances/secrets) get bundled into a given deployed
 * function — never this common request pipeline. See
 * `docs/backend/architecture.md`'s "Cloud Functions" section.
 *
 * Governance (the per-uid daily request cap, and — on the three
 * credit-gated routes — the credit/cap check) is deliberately NOT mounted
 * here. `middleware/governance.ts`'s `rateLimitOnly` and
 * `middleware/creditGate.ts`'s `creditGate` both touch the same Firestore
 * doc (`users/{uid}/meta/usage`); mounting both a blanket rate limiter here
 * AND a per-route credit gate on top of it would touch that doc twice per
 * credit-gated request. Each `buildXApp()` below mounts exactly one
 * governance middleware per route instead.
 */
function baseApp(): Express {
  const app = express();
  app.use(express.json({ limit: "15mb" })); // headroom over the ~10MB post-downscale image payloads
  app.use(requestLogger);
  app.use(verifyAuth);
  return app;
}

/**
 * Low-memory/short-timeout deployment (`proxyApi`): cheap passthrough calls
 * only — `/openrouter/chat` (vision-tagging, profile derivation,
 * intent-extraction, background isolation) and `/pexels/search` are
 * uncapped beyond `rateLimitOnly`'s daily guardrail.
 * `/openrouter/recommend` reuses the same `openrouterChatRouter` handler as
 * `/openrouter/chat` — the separate mount point exists solely to attach
 * `idempotencyGate("RECOMMENDATION")` + `responseCache("recommendation")` +
 * `creditGate("RECOMMENDATION")`. `idempotencyGate` runs first (see
 * `middleware/idempotency.ts`) so a client-declared retry (same
 * `X-Idempotency-Key`) of an already-completed call short-circuits before
 * either the content-hash cache or the credit debit — and so a failed
 * upstream call downstream of `creditGate` can be refunded.
 * `/openrouter/chat` is deliberately NOT idempotency-gated: it's
 * uncapped/no credit cost, so there's nothing to deduplicate.
 */
export function buildProxyApp(): Express {
  const app = baseApp();
  app.use(
    "/openrouter/recommend",
    idempotencyGate("RECOMMENDATION"),
    responseCache("recommendation"),
    creditGate("RECOMMENDATION"),
    openrouterChatRouter
  );
  app.use("/openrouter/chat", rateLimitOnly, openrouterChatRouter);
  app.use("/pexels/search", rateLimitOnly, pexelsSearchRouter);
  return app;
}

/**
 * Higher-memory/long-timeout deployment (`heavyApi`): the two real
 * generation-cost image routes only, both credit-gated under the same
 * "IMAGE_GEN" operation type — `/openrouter/tryon` (chat-completion image
 * models) and `/openrouter/images` (the dedicated-Images-API branch the
 * same two services fall back to when `ModelConfig.isChatCompletionImageModel`
 * is false — see `docs/decisions/resolved-v1.md`). Both are
 * `idempotencyGate`d before `creditGate` — see `buildProxyApp`'s doc comment
 * above; the rationale is identical, and matters even more here given the
 * 60-180s upstream latency these routes' long timeouts exist to
 * accommodate.
 */
export function buildHeavyApp(): Express {
  const app = baseApp();
  app.use("/openrouter/tryon", idempotencyGate("IMAGE_GEN"), creditGate("IMAGE_GEN"), openrouterChatRouter);
  app.use("/openrouter/images", idempotencyGate("IMAGE_GEN"), creditGate("IMAGE_GEN"), openrouterImagesRouter);
  return app;
}

/**
 * Payments/account-management deployment (`accountApi`), isolated from
 * generation traffic so a provider outage or quota spike on
 * proxyApi/heavyApi can't starve deletes, IAP verification, or config
 * reads. All four routes are the deliberate business-logic exceptions to
 * the passthrough-proxy posture — see `app.ts`'s prior single-function doc
 * comment history and `docs/backend/architecture.md` for the individual
 * justifications (Admin SDK privileges / server-only-write access). None
 * of the four touch `openRouterApiKey`/`pexelsApiKey`, so this deployment
 * binds no provider secrets. All four are behind `rateLimitOnly`'s daily
 * guardrail — none carry a per-feature quota.
 */
export function buildAccountApp(): Express {
  const app = baseApp();
  app.use("/account/delete", rateLimitOnly, accountDeleteRouter);
  app.use("/iap/verify", rateLimitOnly, iapVerifyRouter);
  app.use("/entitlement/limits", rateLimitOnly, entitlementLimitsRouter);
  app.use("/analytics/config", rateLimitOnly, responseCache("analyticsConfig"), analyticsConfigRouter);
  return app;
}
