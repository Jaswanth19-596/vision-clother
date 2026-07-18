import type { NextFunction, Response } from "express";
import { FieldValue, getFirestore } from "firebase-admin/firestore";
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

/**
 * Lifetime purchased-credit balances (StoreKit consumable top-ups, granted
 * by `routes/iapVerify.ts`). Deliberately NOT keyed by `periodKey` — they
 * never expire and never reset on the monthly rollover. Consumption order:
 * the monthly free tier is always exhausted first; only then does a request
 * draw one credit from the matching balance.
 */
const BALANCE_FIELD: Record<QuotaFeature, "purchasedRecommendationBalance" | "purchasedTryOnBalance"> = {
  recommendation: "purchasedRecommendationBalance",
  tryOn: "purchasedTryOnBalance",
};

function periodKey(): string {
  return new Date().toISOString().slice(0, 7); // YYYY-MM, UTC
}

/**
 * Below this many requests of headroom under the tier limit, quotaGate falls
 * back to the transactional slow path instead of the non-transactional fast
 * path. Must stay comfortably under the smallest positive tier limit (free
 * tryOn = 10) so the slow path reliably takes over before a request could
 * actually cross the cap without the transaction's atomic guarantee.
 */
const QUOTA_SAFETY_MARGIN = 3;

/**
 * Must run after verifyAuth (needs req.uid/isAnonymous). Checks and
 * increments a per-uid monthly usage counter in Firestore, lazily resetting
 * it when the calendar month rolls over — no cron needed, mirrors
 * rateLimit.ts's per-day doc approach at monthly granularity. When the
 * monthly free tier is exhausted, a request instead draws one credit from
 * the feature's lifetime purchased balance (StoreKit top-ups, granted by
 * routes/iapVerify.ts) before the 429 fires — so a 429 always means "free
 * tier used AND no purchased credits".
 *
 * Two paths, chosen by a non-transactional pre-read:
 *  - Fast path (comfortably under the cap, no rollover due): a single
 *    non-transactional atomic FieldValue.increment write. This doc is keyed
 *    per uid, so the only possible contention is one account's own
 *    overlapping requests — not cross-user load — and this path never
 *    touches the purchased-balance field, so it can't race iapVerify.ts's
 *    grant transaction.
 *  - Slow path (within QUOTA_SAFETY_MARGIN of the cap, over it, or a
 *    monthly rollover is due): the original transaction, re-reading fresh
 *    state (never reusing the pre-read, which may be stale by now) —
 *    required because the purchased-credit drawdown is real money and must
 *    stay serialized against iapVerify.ts's concurrent grant.
 *
 * On a Firestore hiccup: fails open for linked accounts, fails closed for
 * anonymous/guest requests — see `rateLimit.ts`'s matching posture and
 * rationale (guest accounts are free to mint, so are the actual cost-abuse
 * vector; a real linked account hitting a transient Firestore error
 * shouldn't lose the whole AI feature set over it).
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
      const [preUsageSnap, preEntitlementSnap] = await Promise.all([
        usageRef.get(),
        entitlementRef.get(),
      ]);

      const preTier: Tier = req.isAnonymous
        ? "guest"
        : preEntitlementSnap.exists && preEntitlementSnap.data()?.tier === "premium"
          ? "premium"
          : "free";
      const preLimits = TIER_LIMITS[preTier];
      if (!preLimits) {
        logEvent("warn", "quota.tierUnavailable", { requestId: req.requestId, uid, feature });
        res.status(403).json({ error: "tier_unavailable" });
        return;
      }

      const preLimit = preLimits[feature];
      if (preLimit <= 0) {
        logEvent("info", "quota.signInRequired", { requestId: req.requestId, uid, feature });
        res.status(403).json({ error: "sign_in_required" });
        return;
      }

      const preUsageData = preUsageSnap.exists ? preUsageSnap.data() : undefined;
      const preSamePeriod = preUsageData?.periodKey === currentPeriod;
      const preCurrentCount = preSamePeriod
        ? ((preUsageData?.[COUNT_FIELD[feature]] as number) ?? 0)
        : 0;
      const needsSlowPath = !preSamePeriod || preCurrentCount + QUOTA_SAFETY_MARGIN >= preLimit;

      if (!needsSlowPath) {
        // FAST PATH — plenty of headroom, no rollover due.
        await usageRef.set(
          { [COUNT_FIELD[feature]]: FieldValue.increment(1), updatedAt: Date.now() },
          { merge: true }
        );
        logEvent("debug", "quota.ok", { requestId: req.requestId, uid, feature });
        next();
        return;
      }

      // SLOW PATH — near/at the cap, or a rollover is due. Re-read fresh
      // inside the transaction; do not reuse the pre-read above.
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
        // Lifetime field — read regardless of samePeriod; the monthly
        // rollover must never touch purchased balances.
        const purchasedBalance = (usageData?.[BALANCE_FIELD[feature]] as number) ?? 0;

        // All writes below are field-scoped `merge: true` sets that touch
        // ONLY the fields this middleware owns (periodKey, the two counts,
        // updatedAt — plus exactly one balance field on the drawdown path).
        // `routes/iapVerify.ts` may be granting a top-up in its own
        // concurrent transaction; a full-doc overwrite computed from this
        // transaction's read would race it and wipe the just-granted
        // credits. Field-scoped merges keep the two writers commutative.
        if (currentCount >= limit) {
          if (purchasedBalance <= 0) {
            return { outcome: "quota_exceeded" as const, limit };
          }
          // Free tier exhausted — draw one purchased credit. Counts are
          // still written so a cross-month first-request-of-the-month
          // resets them (the write is what persists the rollover).
          tx.set(
            usageRef,
            {
              periodKey: currentPeriod,
              recommendationCount,
              tryOnCount,
              [BALANCE_FIELD[feature]]: purchasedBalance - 1,
              updatedAt: Date.now(),
            },
            { merge: true }
          );
          return { outcome: "ok_purchased" as const, remainingBalance: purchasedBalance - 1 };
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
          { merge: true }
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
          // By construction this only fires when the purchased balance is
          // also 0 (a positive balance takes the ok_purchased path), so the
          // additive purchasedBalance field lets clients say "buy credits"
          // rather than just "wait for the reset".
          logEvent("info", "quota.exceeded", { requestId: req.requestId, uid, feature, limit: result.limit, period: currentPeriod });
          res.status(429).json({ error: "quota_exceeded", limit: result.limit, period: currentPeriod, purchasedBalance: 0 });
          return;
        case "ok_purchased":
          logEvent("info", "quota.purchasedCreditUsed", { requestId: req.requestId, uid, feature, remainingBalance: result.remainingBalance });
          next();
          return;
        case "ok":
          logEvent("debug", "quota.ok", { requestId: req.requestId, uid, feature });
          next();
          return;
      }
    } catch (error) {
      if (req.isAnonymous) {
        logEvent("error", "quota.failClosed", { requestId: req.requestId, uid, feature, error: String(error) });
        res.status(503).json({ error: "temporarily_unavailable" });
        return;
      }
      // Firestore hiccup shouldn't take down the proxy for a linked
      // account — fail open on the quota gate itself, same posture as
      // rateLimit.ts.
      logEvent("error", "quota.failOpen", { requestId: req.requestId, uid, feature, error: String(error) });
      next();
    }
  };
}
