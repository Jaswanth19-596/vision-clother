import type { NextFunction, Response } from "express";
import { FieldValue, getFirestore } from "firebase-admin/firestore";
import type { AuthedRequest } from "../types";
import { logEvent } from "../logger";
import { usageRefFor, entitlementRefFor } from "./governance";
import {
  DEFAULT_TIER_CONFIGS,
  getPricingConfig,
  type OperationType,
  type PricingConfig,
  type TierConfig,
} from "../pricing.config";

export type { OperationType };
export type GateStatus = "UNAUTHENTICATED" | "INSUFFICIENT_CREDITS" | "CAP_REACHED" | "ALLOWED";

/**
 * Frozen snapshot of the old `entitlementLimits.ts`'s `TIER_LIMITS`
 * (guest/free/premium, renamed to GUEST/FREE/PRO) — used ONLY by the
 * one-time legacy-doc migration formula below to convert a pre-rewrite
 * user's remaining count-based headroom into a starting credit balance.
 * Deliberately not exported/reused anywhere else; this is migration math,
 * not live config (see `pricing.config.ts` for that).
 */
const LEGACY_TIER_LIMITS: Record<string, { recommendation: number; tryOn: number }> = {
  GUEST: { recommendation: 20, tryOn: 0 },
  FREE: { recommendation: 100, tryOn: 10 },
  PRO: { recommendation: 500, tryOn: 100 },
};

function emptyUsageCounts(): Record<OperationType, number> {
  return { UPLOAD: 0, IMAGE_GEN: 0, RECOMMENDATION: 0 };
}

/**
 * UTC calendar-month add for the rolling billing-cycle anniversary
 * (confirmed with the user over a fixed-30-day window). `setUTCMonth`
 * clamps an overflowing day-of-month forward (e.g. Jan 31 + 1 month lands
 * on Mar 2/3, not Feb 31) — an accepted quirk of JS Date arithmetic for a
 * rough billing anniversary, not a precise calendar library.
 */
function addUTCMonths(epochMs: number, months: number): number {
  const d = new Date(epochMs);
  d.setUTCMonth(d.getUTCMonth() + months);
  return d.getTime();
}

type GateOutcome =
  | { status: "CAP_REACHED"; cap: number; used: number }
  | { status: "INSUFFICIENT_CREDITS"; creditsRemaining: number; cost: number }
  | { status: "ALLOWED"; cost: number; subscriptionDebited: number; purchasedDebited: number };

function resolveTierConfig(tierId: string, pricingConfig: PricingConfig): TierConfig {
  return pricingConfig.tierConfigs[tierId] ?? pricingConfig.tierConfigs.FREE ?? DEFAULT_TIER_CONFIGS.FREE;
}

/** Sum of both wallet buckets — the actual amount a user can spend right now. */
export function totalCredits(subscriptionCreditsRemaining: number, purchasedCreditsRemaining: number): number {
  return subscriptionCreditsRemaining + purchasedCreditsRemaining;
}

/**
 * Sequential gatekeeper for the credit & tier engine — replaces
 * `governance.ts`'s `governanceGate`/`refundQuota`. Always transactional
 * (`runTransaction`, no warm-instance fast-path cache): unlike the old
 * fixed-safety-margin count check, operation costs and tier definitions are
 * now config-driven and can change at ops pace, so a cached approximation
 * doesn't generalize cleanly — confirmed with the user as an accepted
 * latency/Firestore-cost tradeoff for correctness. `rateLimitOnly`'s coarse
 * daily-request cap (unrelated to credits) is untouched in `governance.ts`.
 *
 * Split wallet: `subscription_credits_remaining` (the monthly/one-time tier
 * allocation, refilled by `autoReset`) and `purchased_credits_remaining` (IAP
 * top-ups, `routes/iapVerify.ts` — NEVER reset) are tracked as two separate
 * Firestore fields instead of one pool. This is required for Apple IAP
 * compliance: a paid consumable top-up must remain the user's property until
 * spent, and folding it into a field that a subscription's monthly reset
 * flat-overwrites would silently erase paid credits. Debits draw from
 * `subscription_credits_remaining` first, then `purchased_credits_remaining`
 * for any remainder — so free/allocated credits are always used up before
 * touching money the user actually paid for.
 *
 * Runs, in order, inside one Firestore transaction over
 * `users/{uid}/meta/usage`:
 *  1. Lazy init/migration — a doc with no `tier_id` yet (a genuinely new
 *     account, or a pre-rewrite legacy user) is initialized/migrated in
 *     this same transaction.
 *  2. Billing reset — recurring tiers (`autoReset: true`) past their
 *     `billing_cycle_start` anniversary get `subscription_credits_remaining`
 *     refilled to the tier's `creditAllocation` and `usage_counts` zeroed.
 *     `purchased_credits_remaining` is never touched by this step. Non-
 *     recurring tiers (FREE/GUEST one-time welcome pack) never auto-reset.
 *  3. Hard cap check — `tierConfig.hardCaps[operation]` vs this cycle's
 *     usage count.
 *  4. Credit balance check — `OPERATION_COSTS[operation]` vs
 *     `totalCredits(subscription, purchased)`; only `INSUFFICIENT_CREDITS`
 *     when the combined balance can't cover the cost.
 * Only on the ALLOWED outcome does the transaction actually write anything
 * (debit + increment) — same minimalism as the old `governanceGate`, which
 * only persisted on its "ok"/"ok_purchased" outcomes; a rejected request
 * just recomputes the same numbers next time, nothing is lost.
 *
 * On a Firestore hiccup: fails open for linked accounts, fails closed for
 * anonymous/guest requests — same posture as every other gate in this
 * backend.
 */
export function creditGate(operation: OperationType) {
  return async (req: AuthedRequest, res: Response, next: NextFunction): Promise<void> => {
    const uid = req.uid;
    if (!uid) {
      res.status(401).json({ error: "missing_id_token" });
      return;
    }

    try {
      const pricingConfig = await getPricingConfig(req.requestId);
      const usageRef = usageRefFor(uid);
      const entitlementRef = entitlementRefFor(uid);

      const result = await getFirestore().runTransaction<GateOutcome>(async (tx) => {
        const [usageSnap, entitlementSnap] = await Promise.all([tx.get(usageRef), tx.get(entitlementRef)]);
        const usageData = usageSnap.exists ? usageSnap.data() : undefined;
        const entitlementData = entitlementSnap.exists ? entitlementSnap.data() : undefined;

        let tierId: string;
        let subscriptionCreditsRemaining: number;
        let purchasedCreditsRemaining: number;
        let billingCycleStart: number;
        let usageCounts: Record<OperationType, number>;
        const welcomePackClaimed: boolean = usageData?.tier_id
          ? Boolean(usageData.welcome_pack_claimed)
          : true; // either a fresh FREE signup claiming it now, or a legacy user who never gets a second one

        if (usageData?.tier_id) {
          tierId = usageData.tier_id as string;
          subscriptionCreditsRemaining = (usageData.subscription_credits_remaining as number) ?? 0;
          purchasedCreditsRemaining = (usageData.purchased_credits_remaining as number) ?? 0;
          billingCycleStart = (usageData.billing_cycle_start as number) ?? Date.now();
          usageCounts = {
            ...emptyUsageCounts(),
            ...(usageData.usage_counts as Partial<Record<OperationType, number>> | undefined),
          };
        } else if (usageData) {
          // Pre-rewrite legacy user: a usage doc exists (dayKey/periodKey/
          // count fields) but has never been touched by creditGate before.
          tierId = req.isAnonymous ? "GUEST" : entitlementData?.tier === "premium" ? "PRO" : "FREE";
          const initTierConfig = resolveTierConfig(tierId, pricingConfig);
          const legacyLimits = LEGACY_TIER_LIMITS[tierId] ?? LEGACY_TIER_LIMITS.FREE;
          const legacyRecommendationCount = (usageData.recommendationCount as number) ?? 0;
          const legacyTryOnCount = (usageData.tryOnCount as number) ?? 0;
          const legacyPurchasedRecommendation = (usageData.purchasedRecommendationBalance as number) ?? 0;
          const legacyPurchasedTryOn = (usageData.purchasedTryOnBalance as number) ?? 0;

          // Convert leftover count-based headroom into the subscription
          // bucket at today's cost, floored at the tier's own allocation so
          // no legacy user is credited less than a brand-new signup would be
          // (see docs/timeline.md's migration write-up). Any old purchased
          // balance carries straight across 1:1 into the purchased bucket —
          // kept separate from the floor so it's never silently absorbed
          // into (or capped by) the subscription allocation.
          const derivedFromHeadroom =
            Math.max(0, legacyLimits.recommendation - legacyRecommendationCount) * pricingConfig.operationCosts.RECOMMENDATION +
            Math.max(0, legacyLimits.tryOn - legacyTryOnCount) * pricingConfig.operationCosts.IMAGE_GEN;

          subscriptionCreditsRemaining = Math.max(initTierConfig.creditAllocation, derivedFromHeadroom);
          purchasedCreditsRemaining = legacyPurchasedRecommendation + legacyPurchasedTryOn;
          billingCycleStart = Date.now();
          usageCounts = emptyUsageCounts();
        } else {
          // Genuinely fresh account — no usage doc at all yet. Grants
          // exactly the tier's own allocation, no legacy-headroom formula
          // (that formula is only meaningful for a pre-existing doc).
          tierId = req.isAnonymous ? "GUEST" : "FREE";
          const initTierConfig = resolveTierConfig(tierId, pricingConfig);
          subscriptionCreditsRemaining = initTierConfig.creditAllocation;
          purchasedCreditsRemaining = 0;
          billingCycleStart = Date.now();
          usageCounts = emptyUsageCounts();
        }

        const tierConfig = resolveTierConfig(tierId, pricingConfig);

        // Roll forward across every missed billing anniversary (a dormant
        // PRO account returning after months away doesn't accumulate
        // allocations — each cycle is a flat refill, not additive). Only the
        // subscription bucket resets; purchased credits are permanent and
        // must never be touched here (Apple IAP compliance).
        while (tierConfig.autoReset && Date.now() >= addUTCMonths(billingCycleStart, 1)) {
          billingCycleStart = addUTCMonths(billingCycleStart, 1);
          subscriptionCreditsRemaining = tierConfig.creditAllocation;
          usageCounts = emptyUsageCounts();
        }

        const cap = tierConfig.hardCaps?.[operation];
        if (cap !== undefined && usageCounts[operation] >= cap) {
          return { status: "CAP_REACHED", cap, used: usageCounts[operation] };
        }

        const cost = pricingConfig.operationCosts[operation];
        const available = totalCredits(subscriptionCreditsRemaining, purchasedCreditsRemaining);
        if (available < cost) {
          return { status: "INSUFFICIENT_CREDITS", creditsRemaining: available, cost };
        }

        // Debit subscription credits first, purchased credits only for
        // whatever the subscription bucket can't cover.
        const subscriptionDebited = Math.min(subscriptionCreditsRemaining, cost);
        const purchasedDebited = cost - subscriptionDebited;
        subscriptionCreditsRemaining -= subscriptionDebited;
        purchasedCreditsRemaining -= purchasedDebited;

        tx.set(
          usageRef,
          {
            tier_id: tierId,
            subscription_credits_remaining: subscriptionCreditsRemaining,
            purchased_credits_remaining: purchasedCreditsRemaining,
            billing_cycle_start: billingCycleStart,
            usage_counts: { ...usageCounts, [operation]: usageCounts[operation] + 1 },
            welcome_pack_claimed: welcomePackClaimed,
            updatedAt: Date.now(),
          },
          { merge: true }
        );
        return { status: "ALLOWED", cost, subscriptionDebited, purchasedDebited };
      });

      switch (result.status) {
        case "CAP_REACHED":
          logEvent("info", "creditGate.capReached", { requestId: req.requestId, uid, operation, cap: result.cap, used: result.used });
          res.status(429).json({ error: "cap_reached", cap: result.cap, used: result.used });
          return;
        case "INSUFFICIENT_CREDITS":
          logEvent("info", "creditGate.insufficientCredits", {
            requestId: req.requestId,
            uid,
            operation,
            creditsRemaining: result.creditsRemaining,
            cost: result.cost,
          });
          res.status(429).json({ error: "insufficient_credits", creditsRemaining: result.creditsRemaining, cost: result.cost });
          return;
        case "ALLOWED":
          req.quotaDebit = {
            operation,
            subscriptionDebited: result.subscriptionDebited,
            purchasedDebited: result.purchasedDebited,
          };
          logEvent("debug", "creditGate.ok", { requestId: req.requestId, uid, operation, cost: result.cost });
          next();
          return;
      }
    } catch (error) {
      if (req.isAnonymous) {
        logEvent("error", "creditGate.failClosed", { requestId: req.requestId, uid, operation, error: String(error) });
        res.status(503).json({ error: "temporarily_unavailable" });
        return;
      }
      logEvent("error", "creditGate.failOpen", { requestId: req.requestId, uid, operation, error: String(error) });
      next();
    }
  };
}

/**
 * Undoes exactly the debit `creditGate` recorded on `req.quotaDebit` —
 * called by `middleware/idempotency.ts` when the request this debit was
 * gating ends up failing downstream, so a failed paid call never
 * permanently costs the user credits. A no-op if `creditGate` never
 * actually debited anything for this request.
 *
 * Runs inside a Firestore transaction so the refund write is serialized
 * against any concurrent `creditGate` transaction on the same doc, and
 * restores credits to the exact bucket(s) — `subscription_credits_remaining`
 * and/or `purchased_credits_remaining` — the original debit actually drew
 * from (recorded on `req.quotaDebit` at debit time), never a single
 * undifferentiated field.
 */
export async function refundCredit(req: AuthedRequest): Promise<void> {
  const debit = req.quotaDebit;
  const uid = req.uid;
  if (!debit || !uid) {
    return;
  }

  const usageRef = usageRefFor(uid);
  await getFirestore().runTransaction(async (tx) => {
    tx.set(
      usageRef,
      {
        subscription_credits_remaining: FieldValue.increment(debit.subscriptionDebited),
        purchased_credits_remaining: FieldValue.increment(debit.purchasedDebited),
        [`usage_counts.${debit.operation}`]: FieldValue.increment(-1),
        updatedAt: Date.now(),
      },
      { merge: true }
    );
  });

  logEvent("info", "creditGate.refunded", {
    requestId: req.requestId,
    uid,
    operation: debit.operation,
    subscriptionDebited: debit.subscriptionDebited,
    purchasedDebited: debit.purchasedDebited,
  });
  req.quotaDebit = undefined;
}
