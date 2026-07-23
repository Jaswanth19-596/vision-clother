import type { NextFunction, Response } from "express";
import { FieldValue, getFirestore } from "firebase-admin/firestore";
import type { AuthedRequest } from "../types";
import { logEvent } from "../logger";

/** Coarse per-user daily request cap, shared across all routes. */
const DAILY_REQUEST_LIMIT = 500;

/**
 * Below this many requests of headroom under the daily cap, `rateLimitOnly`
 * falls back to the transactional slow path instead of the in-memory/
 * non-transactional fast path.
 */
const RATE_LIMIT_SAFETY_MARGIN = 10;

/** Warm-instance in-memory cache TTL — see module doc comment below. */
const CACHE_TTL_MS = 20_000;

/** Coarse bound on distinct uids cached per warm instance; not a real LRU. */
const MAX_CACHE_ENTRIES = 1000;

function todayKey(): string {
  return new Date().toISOString().slice(0, 10); // YYYY-MM-DD, UTC
}

interface CacheEntry {
  cachedAt: number;
  dayKey: string;
  dailyRequestCount: number;
}

/**
 * Module-scope, so it survives across requests on the same warm Cloud
 * Function instance but is never shared cross-instance — see the "Warm-
 * instance cache" doc comment on `rateLimitOnly` below for the consistency
 * trade this implies.
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

/**
 * `users/{uid}/meta/usage` — the shared per-user hot doc. Owned jointly by
 * `rateLimitOnly` (below; `dayKey`/`dailyRequestCount`) and
 * `middleware/creditGate.ts` (`tier_id`/`subscription_credits_remaining`/
 * `purchased_credits_remaining`/`billing_cycle_start`/`usage_counts`/
 * `welcome_pack_claimed`) — both writers use field-scoped `merge: true`/
 * `FieldValue.increment` so they stay commutative on the same doc. Exported
 * so `creditGate.ts` doesn't need its own copy of the ref-building call.
 */
export function usageRefFor(uid: string) {
  return getFirestore().collection("users").doc(uid).collection("meta").doc("usage");
}

/**
 * `users/{uid}/meta/entitlement` — legacy tier field, no longer written by
 * anything (tier now lives on `meta/usage.tier_id`, see `creditGate.ts`).
 * Kept read-only for `creditGate.ts`'s one-time legacy-user migration
 * lookup; safe to remove once every active account has been migrated.
 */
export function entitlementRefFor(uid: string) {
  return getFirestore().collection("users").doc(uid).collection("meta").doc("entitlement");
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
 * request cap for routes with no per-operation credit cost
 * (`/openrouter/chat`, `/pexels/search`, and all four `accountApi` routes) —
 * the three credit-gated routes (`/openrouter/recommend`, `/openrouter/tryon`,
 * `/openrouter/images`) are NOT behind `rateLimitOnly`; `middleware/creditGate.ts`'s
 * credit/cap checks are the only gate there. A cheap abuse guardrail, not a
 * billing/metering system. Touches only the `dayKey`/`dailyRequestCount`
 * fields of the shared `users/{uid}/meta/usage` doc (see `usageRefFor`'s doc
 * comment for the other writer on this doc).
 *
 * Warm-instance cache: on a cache hit that's fresh, same-day, and
 * comfortably under `DAILY_REQUEST_LIMIT` (by `RATE_LIMIT_SAFETY_MARGIN`),
 * the request is allowed immediately off the in-memory counter and the
 * Firestore write is fired without being awaited — zero synchronous
 * Firestore latency on the common path. Otherwise (cache miss/expired, a
 * day rollover is due, or within the safety margin of the cap) falls back
 * to a non-transactional read + write against Firestore — this doc is keyed
 * per uid, so the only possible contention is a single account's own
 * overlapping requests, an acceptable trade for a coarse guardrail that
 * explicitly isn't a hard billing boundary.
 *
 * On a Firestore hiccup: fails open for linked accounts, fails closed for
 * anonymous/guest requests (guest accounts are free to mint and are the
 * actual abuse vector this guardrail exists for).
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
