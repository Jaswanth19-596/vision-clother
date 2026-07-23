import { Router } from "express";
import { getFirestore } from "firebase-admin/firestore";
import type { AuthedRequest } from "../types";
import { logEvent } from "../logger";
import { CORE_SLOTS, ACCESSORY_SLOTS, getPricingConfig, getTierConfig } from "../pricing.config";
import { totalCredits } from "../middleware/creditGate";

export const entitlementLimitsRouter = Router();

/**
 * Deliberate business-logic exception to this file's usual "no business
 * logic past verifyAuth" posture (see app.ts, alongside accountDelete/
 * iapVerify) — the whole point of this route is resolving a tier into
 * concrete numbers server-side, so `Data/UsageTracker.swift` never has to
 * hardcode a tier→number table of its own. Read-only, no mutation, so
 * there's no client-controllable input to worry about beyond the
 * already-verified `req.uid`.
 *
 * Tier resolution: reads `meta/usage.tier_id`, the same field
 * `middleware/creditGate.ts` writes/reads — this route deliberately does
 * NOT run the credit gate's lazy-init/migration logic (it's read-only), so
 * a uid that has never made a credit-gated request yet reads as its
 * about-to-be-assigned tier (GUEST for anonymous, else FREE) with FREE's
 * numbers, matching what `creditGate` would actually initialize on first
 * use. A Firestore read failure here falls back to FREE (never PRO) — this
 * route grants no credits itself, it only describes numbers the real gate
 * enforces independently, so worst case is a temporarily-wrong display, not
 * a bypass.
 */
entitlementLimitsRouter.get("/", async (req: AuthedRequest, res) => {
  const uid = req.uid;
  if (!uid) {
    res.status(401).json({ error: "missing_id_token" });
    return;
  }

  const pricingConfig = await getPricingConfig(req.requestId);

  let tierId = req.isAnonymous ? "GUEST" : "FREE";
  let creditsRemaining: number | undefined;
  let billingCycleStart: number | undefined;

  try {
    const snap = await getFirestore().collection("users").doc(uid).collection("meta").doc("usage").get();
    const data = snap.exists ? snap.data() : undefined;
    if (data?.tier_id) {
      tierId = data.tier_id as string;
      creditsRemaining = totalCredits(
        (data.subscription_credits_remaining as number) ?? 0,
        (data.purchased_credits_remaining as number) ?? 0
      );
      billingCycleStart = data.billing_cycle_start as number;
    }
  } catch (error) {
    logEvent("warn", "entitlementLimits.usageReadFailed", { requestId: req.requestId, uid, error: String(error) });
  }

  const tierConfig = getTierConfig(tierId, pricingConfig) ?? getTierConfig("FREE", pricingConfig);
  if (!tierConfig) {
    logEvent("warn", "entitlementLimits.tierUnavailable", { requestId: req.requestId, uid, tierId });
    res.status(403).json({ error: "tier_unavailable" });
    return;
  }

  const itemCap: Record<string, number> = {};
  for (const slot of CORE_SLOTS) itemCap[slot] = tierConfig.itemCap.core;
  for (const slot of ACCESSORY_SLOTS) itemCap[slot] = tierConfig.itemCap.accessory;

  logEvent("debug", "entitlementLimits.ok", { requestId: req.requestId, uid, tier: tierId });
  res.status(200).json({
    tier: tierId,
    creditsRemaining: creditsRemaining ?? tierConfig.creditAllocation,
    creditAllocation: tierConfig.creditAllocation,
    operationCosts: pricingConfig.operationCosts,
    operationCaps: tierConfig.hardCaps ?? {},
    billingCycleStart: billingCycleStart ?? null,
    autoReset: tierConfig.autoReset,
    itemCap,
  });
});
