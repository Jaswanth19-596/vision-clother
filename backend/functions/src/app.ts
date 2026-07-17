import express from "express";
import type { NextFunction, Response } from "express";
import { verifyAuth } from "./middleware/verifyAuth";
import { rateLimit } from "./middleware/rateLimit";
import { quotaGate } from "./middleware/quota";
import { responseCache } from "./middleware/responseCache";
import { openrouterChatRouter } from "./routes/openrouterChat";
import { openrouterImagesRouter } from "./routes/openrouterImages";
import { pexelsSearchRouter } from "./routes/pexelsSearch";
import { accountDeleteRouter } from "./routes/accountDelete";
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
 * Every route is: verify Firebase Auth -> rate limit -> forward to the
 * provider verbatim. No business logic lives past this point — see
 * docs/backend/conventions.md — with one deliberate exception:
 * `/account/delete` (see `routes/accountDelete.ts`'s doc comment) needs
 * Admin SDK privileges (bulk cross-collection Firestore delete, Storage
 * prefix wipe, deleting the Auth user) the client can never safely hold.
 * App Check is deferred (needs a paid Apple Developer account for App
 * Attest) — see docs/decisions/resolved-v1.md.
 */
export function buildApp(): express.Express {
  const app = express();
  app.use(express.json({ limit: "15mb" })); // headroom over the ~10MB post-downscale image payloads

  app.use(requestLogger);
  app.use(verifyAuth, rateLimit);

  // Recommendation and try-on are quota'd (real generation cost) via a
  // dedicated route each, ahead of the generic pass-through path so the
  // same openrouterChatRouter handler picks up quotaGate for those two
  // features only. Vision-tagging, profile derivation, intent-extraction,
  // and background isolation stay on /openrouter/chat, uncapped beyond the
  // global rateLimit guardrail above — see docs/decisions/resolved-v1.md.
  app.use("/openrouter/recommend", responseCache("recommendation"), quotaGate("recommendation"), openrouterChatRouter);
  app.use("/openrouter/tryon", quotaGate("tryOn"), openrouterChatRouter);
  app.use("/openrouter/chat", openrouterChatRouter);
  // Same "tryOn" feature as /openrouter/tryon above — this is the
  // dedicated-Images-API branch the same two services (try-on render,
  // background isolation) fall back to when ModelConfig points at a
  // non-chat-completion image model (see ModelConfig.isChatCompletionImageModel).
  // Previously ungated: real generation cost reachable by URL alone,
  // independent of which feature/quota the client claims to be using.
  app.use("/openrouter/images", quotaGate("tryOn"), openrouterImagesRouter);
  app.use("/pexels/search", pexelsSearchRouter);
  app.use("/account/delete", accountDeleteRouter);

  return app;
}
