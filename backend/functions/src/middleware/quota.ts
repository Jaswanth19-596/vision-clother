import type { NextFunction, Response } from "express";
import { getFirestore } from "firebase-admin/firestore";
import type { AuthedRequest } from "../types";
import { logEvent } from "../logger";

type QuotaFeature = "recommendation" | "tryOn";
type Tier = "guest" | "free" | "premium";

interface TierLimits {
  recommendation: number;
  tryOn: number;
}

/**
 * Premium is intentionally absent — pricing isn't designed yet. Reaching it
 * (an entitlement doc with tier: "premium") falls through to an explicit
 * "not available yet" 403 rather than silently defaulting to unlimited.
 */
const TIER_LIMITS: Partial<Record<Tier, TierLimits>> = {
  guest: { recommendation: 20, tryOn: 0 },
  free: { recommendation: 100, tryOn: 10 },
};

const COUNT_FIELD: Record<QuotaFeature, "recommendationCount" | "tryOnCount"> = {
  recommendation: "recommendationCount",
  tryOn: "tryOnCount",
};

function periodKey(): string {
  return new Date().toISOString().slice(0, 7); // YYYY-MM, UTC
}

/**
 * Must run after verifyAuth (needs req.uid/isAnonymous). Atomically checks
 * and increments a per-uid monthly usage counter in Firestore, lazily
 * resetting it when the calendar month rolls over — no cron needed, mirrors
 * rateLimit.ts's per-day doc approach at monthly granularity.
 */
export function quotaGate(feature: QuotaFeature) {
  return async (req: AuthedRequest, res: Response, next: NextFunction): Promise<void> => {
    const uid = req.uid;
    if (!uid) {
      res.status(401).json({ error: "missing_id_token" });
      return;
    }

    const db = getFirestore();
    const usageRef = db.collection("users").doc(uid).collection("meta").doc("usage");
    const entitlementRef = db.collection("users").doc(uid).collection("meta").doc("entitlement");
    const currentPeriod = periodKey();

    try {
      const result = await db.runTransaction(async (tx) => {
        const [usageSnap, entitlementSnap] = await Promise.all([
          tx.get(usageRef),
          tx.get(entitlementRef),
        ]);

        const tier: Tier = req.isAnonymous
          ? "guest"
          : entitlementSnap.exists && entitlementSnap.data()?.tier === "premium"
            ? "premium"
            : "free";
        const limits = TIER_LIMITS[tier];
        if (!limits) {
          return { outcome: "tier_unavailable" as const };
        }

        const limit = limits[feature];
        if (limit <= 0) {
          return { outcome: "sign_in_required" as const };
        }

        const usageData = usageSnap.exists ? usageSnap.data() : undefined;
        const samePeriod = usageData?.periodKey === currentPeriod;
        const recommendationCount = samePeriod ? ((usageData?.recommendationCount as number) ?? 0) : 0;
        const tryOnCount = samePeriod ? ((usageData?.tryOnCount as number) ?? 0) : 0;
        const currentCount = feature === "recommendation" ? recommendationCount : tryOnCount;

        if (currentCount >= limit) {
          return { outcome: "quota_exceeded" as const, limit };
        }

        tx.set(
          usageRef,
          {
            periodKey: currentPeriod,
            recommendationCount,
            tryOnCount,
            [COUNT_FIELD[feature]]: currentCount + 1,
            updatedAt: Date.now(),
          },
          { merge: false }
        );

        return { outcome: "ok" as const };
      });

      switch (result.outcome) {
        case "tier_unavailable":
          logEvent("warn", "quota.tierUnavailable", { requestId: req.requestId, uid, feature });
          res.status(403).json({ error: "tier_unavailable" });
          return;
        case "sign_in_required":
          logEvent("info", "quota.signInRequired", { requestId: req.requestId, uid, feature });
          res.status(403).json({ error: "sign_in_required" });
          return;
        case "quota_exceeded":
          logEvent("info", "quota.exceeded", { requestId: req.requestId, uid, feature, limit: result.limit, period: currentPeriod });
          res.status(429).json({ error: "quota_exceeded", limit: result.limit, period: currentPeriod });
          return;
        case "ok":
          logEvent("debug", "quota.ok", { requestId: req.requestId, uid, feature });
          next();
          return;
      }
    } catch (error) {
      // Firestore hiccup shouldn't take down the proxy — fail open on the
      // quota gate itself, same posture as rateLimit.ts.
      logEvent("error", "quota.failOpen", { requestId: req.requestId, uid, feature, error: String(error) });
      next();
    }
  };
}
