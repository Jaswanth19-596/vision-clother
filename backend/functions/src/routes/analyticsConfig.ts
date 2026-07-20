import { Router } from "express";
import type { AuthedRequest } from "../types";
import { logEvent } from "../logger";
import { ANALYTICS_THRESHOLDS } from "../analyticsConfig";

export const analyticsConfigRouter = Router();

/**
 * Fourth deliberate exception to this file's usual "no business logic past
 * verifyAuth" posture (see app.ts, alongside accountDelete/iapVerify/
 * entitlementLimits) — same rationale as `entitlementLimits.ts`: resolves
 * confidence/unlock threshold numbers server-side so
 * `Domain/AnalyticsConfidence.swift` never hardcodes its own copy. Simpler
 * than that route — no tier resolution, every caller gets the same numbers
 * today — but kept as its own endpoint (not folded into `/entitlement/limits`)
 * since the two evolve independently: entitlement limits are billing-driven,
 * analytics thresholds are data-driven.
 *
 * Read-only, no mutation, wrapped in `responseCache` at the `app.ts` mount
 * site (these numbers barely change) — no per-uid business logic runs here
 * beyond requiring a verified caller.
 */
analyticsConfigRouter.get("/", (req: AuthedRequest, res) => {
  const uid = req.uid;
  if (!uid) {
    res.status(401).json({ error: "missing_id_token" });
    return;
  }

  logEvent("debug", "analyticsConfig.ok", { requestId: req.requestId, uid });
  res.status(200).json(ANALYTICS_THRESHOLDS);
});
