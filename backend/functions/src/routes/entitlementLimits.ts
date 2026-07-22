import { Router } from "express";
import { getFirestore } from "firebase-admin/firestore";
import type { AuthedRequest } from "../types";
import { logEvent } from "../logger";
import { TIER_LIMITS, ITEM_CAP_LIMITS, CORE_SLOTS, ACCESSORY_SLOTS, type Tier } from "../entitlementLimits";

export const entitlementLimitsRouter = Router();

/**
 * Deliberate third exception to this file's usual "no business logic past
 * verifyAuth" posture (see app.ts, alongside accountDelete/iapVerify) — the
 * whole point of this route is resolving a tier into concrete numbers
 * server-side, the same computation `middleware/governance.ts`'s
 * `governanceGate` does, so `Data/UsageTracker.swift` never has to hardcode
 * a tier→number table of its own (previously `Domain/EntitlementLimits.swift`,
 * deleted when this route was added — see docs/timeline.md). Read-only, no
 * mutation, so there's no client-controllable input to worry about beyond
 * the already-verified `req.uid`.
 *
 * Tier resolution mirrors `governanceGate` exactly: anonymous is always
 * "guest" regardless of any entitlement doc; otherwise "premium" only if
 * `meta/entitlement.tier` says so, else "free". A Firestore read failure
 * here fails open to "free" (never "premium") — this route grants no
 * quota itself, it only describes numbers the real gates enforce
 * independently, so worst case is a temporarily-wrong display/pre-check,
 * not a bypass.
 */
entitlementLimitsRouter.get("/", async (req: AuthedRequest, res) => {
  const uid = req.uid;
  if (!uid) {
    res.status(401).json({ error: "missing_id_token" });
    return;
  }

  let tier: Tier = "free";
  if (req.isAnonymous) {
    tier = "guest";
  } else {
    try {
      const snap = await getFirestore().collection("users").doc(uid).collection("meta").doc("entitlement").get();
      if (snap.exists && snap.data()?.tier === "premium") {
        tier = "premium";
      }
    } catch (error) {
      logEvent("warn", "entitlementLimits.entitlementReadFailed", { requestId: req.requestId, uid, error: String(error) });
    }
  }

  const tierLimits = TIER_LIMITS[tier];
  const itemCapLimits = ITEM_CAP_LIMITS[tier];
  if (!tierLimits) {
    logEvent("warn", "entitlementLimits.tierUnavailable", { requestId: req.requestId, uid, tier });
    res.status(403).json({ error: "tier_unavailable" });
    return;
  }

  const itemCap: Record<string, number> = {};
  for (const slot of CORE_SLOTS) itemCap[slot] = itemCapLimits.core;
  for (const slot of ACCESSORY_SLOTS) itemCap[slot] = itemCapLimits.accessory;

  logEvent("debug", "entitlementLimits.ok", { requestId: req.requestId, uid, tier });
  res.status(200).json({
    tier,
    recommendationLimit: tierLimits.recommendation,
    tryOnLimit: tierLimits.tryOn,
    itemCap,
  });
});
