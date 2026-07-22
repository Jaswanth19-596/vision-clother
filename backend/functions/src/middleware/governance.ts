import type { NextFunction, Response } from "express";
import { FieldValue, getFirestore } from "firebase-admin/firestore";
import type { AuthedRequest } from "../types";
import { logEvent } from "../logger";
import { TIER_LIMITS, type Tier } from "../entitlementLimits";

export type QuotaFeature = "recommendation" | "tryOn";

const COUNT_FIELD: Record<QuotaFeature, "recommendationCount" | "tryOnCount"> = {
  recommendation: "recommendationCount",
  tryOn: "tryOnCount",
};

/**
 * Lifetime purchased-credit balances (StoreKit consumable top-ups, granted
 * by `routes/iapVerify.ts`). Deliberately NOT keyed by `periodKey` — they
 * never expire and never reset on the monthly rollover.
 */
const BALANCE_FIELD: Record<QuotaFeature, "purchasedRecommendationBalance" | "purchasedTryOnBalance"> = {
  recommendation: "purchasedRecommendationBalance",
  tryOn: "purchasedTryOnBalance",
};

/** Coarse per-user daily request cap, shared across all routes. */
const DAILY_REQUEST_LIMIT = 500;

/**
 * Below this many requests of headroom under the daily cap, governance
 * falls back to the transactional slow path instead of the in-memory/
 * non-transactional fast path. Proportionate to `QUOTA_SAFETY_MARGIN`
 * below, scaled up for the much larger daily limit.
 */
const RATE_LIMIT_SAFETY_MARGIN = 10;

/**
 * Below this many requests of headroom under the tier's monthly limit,
 * governanceGate falls back to the transactional slow path. Must stay
 * comfortably under the smallest positive tier limit (free tryOn = 10) so
 * the slow path reliably takes over before a request could actually cross
 * the cap without the transaction's atomic guarantee.
 */
const QUOTA_SAFETY_MARGIN = 3;

/** Warm-instance in-memory cache TTL — see module doc comment below. */
const CACHE_TTL_MS = 20_000;

/** Coarse bound on distinct uids cached per warm instance; not a real LRU. */
const MAX_CACHE_ENTRIES = 1000;

function todayKey(): string {
  return new Date().toISOString().slice(0, 10); // YYYY-MM-DD, UTC
}

function periodKey(): string {
  return new Date().toISOString().slice(0, 7); // YYYY-MM, UTC
}

interface CacheEntry {
  cachedAt: number;
  dayKey: string;
  dailyRequestCount: number;
  tier?: Tier;
  periodKey?: string;
  recommendationCount?: number;
  tryOnCount?: number;
  purchasedRecommendationBalance?: number;
  purchasedTryOnBalance?: number;
}

/**
 * Module-scope, so it survives across requests on the same warm Cloud
 * Function instance but is never shared cross-instance — see the "Warm-
 * instance cache" doc comment on `rateLimitOnly`/`governanceGate` below for
 * the consistency trade this implies.
 */
const cache = new Map<string, CacheEntry>();

function isFresh(entry: CacheEntry): boolean {
  return Date.now() - entry.cachedAt < CACHE_TTL_MS;
}

function putCache(uid: string, patch: Partial<CacheEntry>): CacheEntry {
  const existing = cache.get(uid);
  const next: CacheEntry = {
    cachedAt: Date.now(),
    dayKey: existing?.dayKey ?? todayKey(),
    dailyRequestCount: existing?.dailyRequestCount ?? 0,
    ...existing,
    ...patch,
    cachedAt: Date.now(),
  };
  if (!cache.has(uid) && cache.size >= MAX_CACHE_ENTRIES) {
    const oldest = cache.keys().next().value;
    if (oldest !== undefined) {
      cache.delete(oldest);
    }
  }
  cache.set(uid, next);
  return next;
}

function usageRefFor(uid: string) {
  return getFirestore().collection("users").doc(uid).collection("meta").doc("usage");
}

function entitlementRefFor(uid: string) {
  return getFirestore().collection("users").doc(uid).collection("meta").doc("entitlement");
}

function resolveTier(isAnonymous: boolean | undefined, entitlementData: Record<string, unknown> | undefined): Tier {
  if (isAnonymous) {
    return "guest";
  }
  return entitlementData?.tier === "premium" ? "premium" : "free";
}

function fireAndForgetSet(
  uid: string,
  requestId: string | undefined,
  data: Record<string, unknown>
): void {
  usageRefFor(uid)
    .set(data, { merge: true })
    .catch((error) => {
      logEvent("error", "governance.asyncWriteFailed", { requestId, uid, error: String(error) });
    });
}

/**
 * Must run after `verifyAuth` (needs `req.uid`). Coarse per-uid daily
 * request cap for routes with no per-feature quota (`/openrouter/chat`,
 * `/pexels/search`, `/account/delete`, `/iap/verify`,
 * `/entitlement/limits`, `/analytics/config`) — cheap abuse guardrail, not
 * a billing/metering system. Touches only the `dayKey`/`dailyRequestCount`
 * fields of the shared `users/{uid}/meta/usage` doc (see `governanceGate`
 * below for the fields it owns on the same doc); both writers use
 * field-scoped `merge: true` so they stay commutative.
 *
 * Warm-instance cache: on a cache hit that's fresh, same-day, and
 * comfortably under `DAILY_REQUEST_LIMIT` (by `RATE_LIMIT_SAFETY_MARGIN`),
 * the request is allowed immediately off the in-memory counter and the
 * Firestore write is fired without being awaited — zero synchronous
 * Firestore latency on the common path. Otherwise (cache miss/expired, a
 * day rollover is due, or within the safety margin of the cap) falls back
 * to a non-transactional read + write against Firestore, same posture as
 * the pre-consolidation `rateLimit.ts`: this doc is keyed per uid, so the
 * only possible contention is a single account's own overlapping requests,
 * an acceptable trade for a coarse guardrail that explicitly isn't a hard
 * billing boundary.
 *
 * On a Firestore hiccup: fails open for linked accounts, fails closed for
 * anonymous/guest requests (guest accounts are free to mint and are the
 * actual abuse vector this guardrail exists for) — same posture as
 * `governanceGate`.
 */
export async function rateLimitOnly(req: AuthedRequest, res: Response, next: NextFunction): Promise<void> {
  const uid = req.uid;
  if (!uid) {
    res.status(401).json({ error: "missing_id_token" });
    return;
  }

  const today = todayKey();
  const cached = cache.get(uid);

  if (
    cached &&
    isFresh(cached) &&
    cached.dayKey === today &&
    cached.dailyRequestCount + RATE_LIMIT_SAFETY_MARGIN < DAILY_REQUEST_LIMIT
  ) {
    putCache(uid, { dailyRequestCount: cached.dailyRequestCount + 1 });
    fireAndForgetSet(uid, req.requestId, {
      dayKey: today,
      dailyRequestCount: FieldValue.increment(1),
      updatedAt: Date.now(),
    });
    next();
    return;
  }

  try {
    const ref = usageRefFor(uid);
    const snap = await ref.get();
    const data = snap.exists ? snap.data() : undefined;
    const sameDay = data?.dayKey === today;
    const currentCount = sameDay ? ((data?.dailyRequestCount as number) ?? 0) : 0;

    if (currentCount >= DAILY_REQUEST_LIMIT) {
      logEvent("warn", "governance.rateLimit.exceeded", { requestId: req.requestId, uid, limit: DAILY_REQUEST_LIMIT });
      res.status(429).json({ error: "rate_limit_exceeded" });
      return;
    }

    // `FieldValue.increment` on the same-day path (not a plain computed
    // value) so this stays atomic against a concurrent fast-path writer on
    // the same doc — this non-transactional read only decides whether to
    // reject, never what value to write. A day rollover is the one case
    // that legitimately needs a plain overwrite: it's establishing the
    // day's first count, not adding to a value we just read.
    await ref.set(
      {
        dayKey: today,
        dailyRequestCount: sameDay ? FieldValue.increment(1) : 1,
        updatedAt: Date.now(),
      },
      { merge: true }
    );
    putCache(uid, { dayKey: today, dailyRequestCount: currentCount + 1 });
    next();
  } catch (error) {
    if (req.isAnonymous) {
      logEvent("error", "governance.rateLimit.failClosed", { requestId: req.requestId, uid, error: String(error) });
      res.status(503).json({ error: "temporarily_unavailable" });
      return;
    }
    logEvent("error", "governance.rateLimit.failOpen", { requestId: req.requestId, uid, error: String(error) });
    next();
  }
}

type SlowPathOutcome =
  | { outcome: "tier_unavailable" }
  | { outcome: "sign_in_required" }
  | { outcome: "rate_limited" }
  | { outcome: "quota_exceeded"; limit: number }
  | {
      outcome: "ok" | "ok_purchased";
      tier: Tier;
      dailyRequestCount: number;
      recommendationCount: number;
      tryOnCount: number;
      purchasedRecommendationBalance: number;
      purchasedTryOnBalance: number;
    };

/**
 * Must run after `verifyAuth` (needs `req.uid`/`req.isAnonymous`). Combines
 * the daily rate-limit check and the monthly quota / purchased-balance
 * check into a single pass over the shared `users/{uid}/meta/usage` doc
 * (plus `users/{uid}/meta/entitlement` for tier — owned by
 * `routes/iapVerify.ts`'s purchase-grant flow, read-only here), replacing
 * the separate `rateLimit.ts` + `quota.ts` middleware and their separate
 * Firestore round trips.
 *
 * Two paths:
 *  - **Fast path** — a fresh, same-day/same-month warm-instance cache hit
 *    (see `rateLimitOnly`'s doc comment for the cache's cross-instance
 *    consistency trade) with both the daily count and the monthly quota
 *    count comfortably under their limits (by `RATE_LIMIT_SAFETY_MARGIN`
 *    and `QUOTA_SAFETY_MARGIN` respectively): bumps the in-memory counters
 *    and calls `next()` immediately; the Firestore write is fired without
 *    being awaited. Deliberately never taken for a purchased-balance
 *    drawdown (see below).
 *  - **Slow path** — cache miss/expired, a day/month rollover is due,
 *    either counter is within its safety margin, or the request would need
 *    to draw a purchased credit: the original transaction, reading both
 *    docs fresh and writing daily + monthly + balance fields together in
 *    one `tx.set`. Purchased-balance drawdown is real money and must stay
 *    serialized against `iapVerify.ts`'s concurrent grant transaction, so
 *    it always takes this path — the in-memory fast path never touches it.
 *
 * All writes are field-scoped `merge: true` sets touching only the fields
 * this middleware owns — never a full-doc overwrite — so this stays
 * commutative with `iapVerify.ts`'s balance grants and `rateLimitOnly`'s
 * daily-count writes on the same doc.
 *
 * On a Firestore hiccup: fails open for linked accounts, fails closed for
 * anonymous/guest requests — same posture as `rateLimitOnly` and the
 * pre-consolidation `rateLimit.ts`/`quota.ts`.
 */
export function governanceGate(feature: QuotaFeature) {
  return async (req: AuthedRequest, res: Response, next: NextFunction): Promise<void> => {
    const uid = req.uid;
    if (!uid) {
      res.status(401).json({ error: "missing_id_token" });
      return;
    }

    const today = todayKey();
    const period = periodKey();
    const cached = cache.get(uid);

    const cacheUsable =
      !!cached &&
      isFresh(cached) &&
      cached.dayKey === today &&
      cached.periodKey === period &&
      cached.tier !== undefined &&
      cached.recommendationCount !== undefined &&
      cached.tryOnCount !== undefined;

    if (cacheUsable) {
      const tier = cached!.tier as Tier;
      const limits = TIER_LIMITS[tier];
      const limit = limits?.[feature];

      if (!limits) {
        logEvent("warn", "governance.tierUnavailable", { requestId: req.requestId, uid, feature });
        res.status(403).json({ error: "tier_unavailable" });
        return;
      }
      if (limit! <= 0) {
        logEvent("info", "governance.signInRequired", { requestId: req.requestId, uid, feature });
        res.status(403).json({ error: "sign_in_required" });
        return;
      }

      const currentCount = feature === "recommendation" ? cached!.recommendationCount! : cached!.tryOnCount!;
      const dailyOk = cached!.dailyRequestCount + RATE_LIMIT_SAFETY_MARGIN < DAILY_REQUEST_LIMIT;
      const quotaOk = currentCount + QUOTA_SAFETY_MARGIN < limit!;

      if (dailyOk && quotaOk) {
        putCache(uid, {
          dailyRequestCount: cached!.dailyRequestCount + 1,
          recommendationCount: feature === "recommendation" ? currentCount + 1 : cached!.recommendationCount,
          tryOnCount: feature === "tryOn" ? currentCount + 1 : cached!.tryOnCount,
        });
        fireAndForgetSet(uid, req.requestId, {
          dayKey: today,
          dailyRequestCount: FieldValue.increment(1),
          periodKey: period,
          [COUNT_FIELD[feature]]: FieldValue.increment(1),
          updatedAt: Date.now(),
        });
        req.quotaDebit = { feature, kind: "count" };
        logEvent("debug", "governance.ok", { requestId: req.requestId, uid, feature });
        next();
        return;
      }
    }

    // SLOW PATH — re-read fresh inside the transaction; never reuse the cache.
    try {
      const usageRef = usageRefFor(uid);
      const entitlementRef = entitlementRefFor(uid);

      const result = await getFirestore().runTransaction<SlowPathOutcome>(async (tx) => {
        const [usageSnap, entitlementSnap] = await Promise.all([tx.get(usageRef), tx.get(entitlementRef)]);

        const tier = resolveTier(req.isAnonymous, entitlementSnap.exists ? entitlementSnap.data() : undefined);
        const limits = TIER_LIMITS[tier];
        if (!limits) {
          return { outcome: "tier_unavailable" };
        }
        const limit = limits[feature];
        if (limit <= 0) {
          return { outcome: "sign_in_required" };
        }

        const usageData = usageSnap.exists ? usageSnap.data() : undefined;

        const sameDay = usageData?.dayKey === today;
        const dailyRequestCount = sameDay ? ((usageData?.dailyRequestCount as number) ?? 0) : 0;
        if (dailyRequestCount >= DAILY_REQUEST_LIMIT) {
          return { outcome: "rate_limited" };
        }

        const samePeriod = usageData?.periodKey === period;
        const recommendationCount = samePeriod ? ((usageData?.recommendationCount as number) ?? 0) : 0;
        const tryOnCount = samePeriod ? ((usageData?.tryOnCount as number) ?? 0) : 0;
        const currentCount = feature === "recommendation" ? recommendationCount : tryOnCount;
        // Lifetime fields — read regardless of samePeriod; the monthly
        // rollover must never touch purchased balances.
        const purchasedRecommendationBalance = (usageData?.purchasedRecommendationBalance as number) ?? 0;
        const purchasedTryOnBalance = (usageData?.purchasedTryOnBalance as number) ?? 0;
        const purchasedBalance = feature === "recommendation" ? purchasedRecommendationBalance : purchasedTryOnBalance;

        const baseFields = {
          dayKey: today,
          dailyRequestCount: dailyRequestCount + 1,
          periodKey: period,
          recommendationCount,
          tryOnCount,
          updatedAt: Date.now(),
        };

        if (currentCount >= limit) {
          if (purchasedBalance <= 0) {
            return { outcome: "quota_exceeded", limit };
          }
          // Free tier exhausted — draw one purchased credit. Counts are
          // still written so a cross-month first-request-of-the-month
          // resets them (the write is what persists the rollover).
          tx.set(usageRef, { ...baseFields, [BALANCE_FIELD[feature]]: purchasedBalance - 1 }, { merge: true });
          return {
            outcome: "ok_purchased",
            tier,
            dailyRequestCount: dailyRequestCount + 1,
            recommendationCount,
            tryOnCount,
            purchasedRecommendationBalance:
              feature === "recommendation" ? purchasedBalance - 1 : purchasedRecommendationBalance,
            purchasedTryOnBalance: feature === "tryOn" ? purchasedBalance - 1 : purchasedTryOnBalance,
          };
        }

        tx.set(usageRef, { ...baseFields, [COUNT_FIELD[feature]]: currentCount + 1 }, { merge: true });
        return {
          outcome: "ok",
          tier,
          dailyRequestCount: dailyRequestCount + 1,
          recommendationCount: feature === "recommendation" ? currentCount + 1 : recommendationCount,
          tryOnCount: feature === "tryOn" ? currentCount + 1 : tryOnCount,
          purchasedRecommendationBalance,
          purchasedTryOnBalance,
        };
      });

      switch (result.outcome) {
        case "tier_unavailable":
          logEvent("warn", "governance.tierUnavailable", { requestId: req.requestId, uid, feature });
          res.status(403).json({ error: "tier_unavailable" });
          return;
        case "sign_in_required":
          logEvent("info", "governance.signInRequired", { requestId: req.requestId, uid, feature });
          res.status(403).json({ error: "sign_in_required" });
          return;
        case "rate_limited":
          logEvent("warn", "governance.rateLimit.exceeded", { requestId: req.requestId, uid, limit: DAILY_REQUEST_LIMIT });
          res.status(429).json({ error: "rate_limit_exceeded" });
          return;
        case "quota_exceeded":
          logEvent("info", "governance.quotaExceeded", { requestId: req.requestId, uid, feature, limit: result.limit, period });
          res.status(429).json({ error: "quota_exceeded", limit: result.limit, period, purchasedBalance: 0 });
          return;
        case "ok_purchased":
        case "ok":
          putCache(uid, {
            dayKey: today,
            dailyRequestCount: result.dailyRequestCount,
            tier: result.tier,
            periodKey: period,
            recommendationCount: result.recommendationCount,
            tryOnCount: result.tryOnCount,
            purchasedRecommendationBalance: result.purchasedRecommendationBalance,
            purchasedTryOnBalance: result.purchasedTryOnBalance,
          });
          req.quotaDebit = { feature, kind: result.outcome === "ok_purchased" ? "purchased" : "count" };
          logEvent(result.outcome === "ok_purchased" ? "info" : "debug", "governance.ok", {
            requestId: req.requestId,
            uid,
            feature,
            purchased: result.outcome === "ok_purchased",
          });
          next();
          return;
      }
    } catch (error) {
      if (req.isAnonymous) {
        logEvent("error", "governance.failClosed", { requestId: req.requestId, uid, feature, error: String(error) });
        res.status(503).json({ error: "temporarily_unavailable" });
        return;
      }
      logEvent("error", "governance.failOpen", { requestId: req.requestId, uid, feature, error: String(error) });
      next();
    }
  };
}

/**
 * Undoes exactly the debit `governanceGate` recorded on `req.quotaDebit` —
 * called by `middleware/idempotency.ts` when the request this debit was
 * gating ends up failing downstream, so a failed paid call never
 * permanently costs the user a recommendation/try-on. A no-op if
 * `governanceGate` never actually debited anything for this request.
 *
 * Field-scoped `FieldValue.increment`, same commutativity rationale as
 * every other write in this file. Also invalidates this uid's cache entry
 * rather than trying to patch it in place — simpler than threading the
 * refund through the in-memory counters, and the next request just takes
 * the slow path once (cheap, one-off).
 */
export async function refundQuota(req: AuthedRequest): Promise<void> {
  const debit = req.quotaDebit;
  const uid = req.uid;
  if (!debit || !uid) {
    return;
  }

  const usageRef = usageRefFor(uid);

  if (debit.kind === "purchased") {
    await usageRef.set(
      { [BALANCE_FIELD[debit.feature]]: FieldValue.increment(1), updatedAt: Date.now() },
      { merge: true }
    );
  } else {
    await usageRef.set(
      { [COUNT_FIELD[debit.feature]]: FieldValue.increment(-1), updatedAt: Date.now() },
      { merge: true }
    );
  }

  cache.delete(uid);
  logEvent("info", "governance.refunded", { requestId: req.requestId, uid, feature: debit.feature, kind: debit.kind });
  req.quotaDebit = undefined;
}
