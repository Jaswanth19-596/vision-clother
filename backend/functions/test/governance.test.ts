import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";
import express from "express";
import request from "supertest";
import type { AuthedRequest } from "../src/types";

type DocKind = "usage" | "entitlement";

let store: Map<string, Record<string, unknown> | undefined>;
let getCalls: Map<string, number>;
let failNextGet: Set<string>;

function key(uid: string, kind: DocKind): string {
  return `${uid}:${kind}`;
}

// Mirrors Firestore's FieldValue.increment: the fast path uses it directly
// (no transaction), the slow path's transaction still uses plain values.
// Faked as a sentinel object a `set` interprets by adding to the field's
// existing value.
function resolveFieldValue(existing: Record<string, unknown> | undefined, k: string, value: unknown): unknown {
  if (value && typeof value === "object" && "__increment" in (value as Record<string, unknown>)) {
    const current = (existing?.[k] as number) ?? 0;
    return current + (value as { __increment: number }).__increment;
  }
  return value;
}

// Mirrors Firestore's merge semantics: `{merge: true}` folds into the
// existing doc field-by-field; a plain set replaces it outright.
function applySet(
  existing: Record<string, unknown> | undefined,
  data: Record<string, unknown>,
  merge: boolean | undefined
): Record<string, unknown> {
  const resolved: Record<string, unknown> = {};
  for (const [k, value] of Object.entries(data)) {
    resolved[k] = resolveFieldValue(existing, k, value);
  }
  return merge ? { ...(existing ?? {}), ...resolved } : resolved;
}

function makeRef(uid: string, kind: DocKind) {
  const k = key(uid, kind);
  return {
    get: async () => {
      if (failNextGet.has(k)) {
        failNextGet.delete(k);
        throw new Error("boom");
      }
      getCalls.set(k, (getCalls.get(k) ?? 0) + 1);
      const data = store.get(k);
      return { exists: data !== undefined, data: () => data };
    },
    set: async (data: Record<string, unknown>, options?: { merge?: boolean }) => {
      store.set(k, applySet(store.get(k), data, options?.merge));
    },
  };
}

const runTransaction = vi.fn(async (fn: (tx: unknown) => Promise<unknown>) => {
  const tx = {
    get: async (ref: ReturnType<typeof makeRef>) => ref.get(),
    set: (ref: ReturnType<typeof makeRef>, data: Record<string, unknown>, options?: { merge?: boolean }) => {
      void ref.set(data, options);
    },
  };
  return fn(tx);
});

vi.mock("firebase-admin/firestore", () => ({
  getFirestore: () => ({
    collection: () => ({
      doc: (uid: string) => ({
        collection: () => ({
          doc: (name: DocKind) => makeRef(uid, name),
        }),
      }),
    }),
    runTransaction,
  }),
  FieldValue: {
    increment: (n: number) => ({ __increment: n }),
  },
}));

import { rateLimitOnly, governanceGate, refundQuota } from "../src/middleware/governance";

function rateLimitApp(uid: string | undefined, isAnonymous = false) {
  const app = express();
  app.use((req: AuthedRequest, _res, next) => {
    req.uid = uid;
    req.isAnonymous = isAnonymous;
    req.requestId = "test-request";
    next();
  });
  app.use(rateLimitOnly);
  app.get("/protected", (_req, res) => res.status(200).json({ ok: true }));
  return app;
}

function quotaApp(uid: string | undefined, isAnonymous: boolean, feature: "recommendation" | "tryOn") {
  const app = express();
  let capturedReq: AuthedRequest | undefined;
  app.use((req: AuthedRequest, _res, next) => {
    req.uid = uid;
    req.isAnonymous = isAnonymous;
    req.requestId = "test-request";
    capturedReq = req;
    next();
  });
  app.use(governanceGate(feature));
  app.get("/protected", (_req, res) => res.status(200).json({ ok: true }));
  return { app, getReq: () => capturedReq };
}

// Allow a single microtask tick for `governanceGate`'s fire-and-forget
// (unawaited) Firestore write to land before assertions read `store`.
async function flush(): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, 0));
}

beforeEach(() => {
  store = new Map();
  getCalls = new Map();
  failNextGet = new Set();
  runTransaction.mockClear();
});

afterEach(() => {
  vi.useRealTimers();
});

describe("rateLimitOnly", () => {
  it("rejects if req.uid is missing (verifyAuth didn't run first)", async () => {
    const res = await request(rateLimitApp(undefined)).get("/protected");
    expect(res.status).toBe(401);
  });

  it("allows a request under the daily limit on a cold cache (slow path)", async () => {
    const uid = "rl-cold-1";
    const res = await request(rateLimitApp(uid)).get("/protected");
    expect(res.status).toBe(200);
    expect(store.get(key(uid, "usage"))?.dailyRequestCount).toBe(1);
    expect(runTransaction).not.toHaveBeenCalled();
  });

  it("rejects once the daily limit is exceeded", async () => {
    const uid = "rl-atcap-1";
    const today = new Date().toISOString().slice(0, 10);
    store.set(key(uid, "usage"), { dayKey: today, dailyRequestCount: 500 });
    const res = await request(rateLimitApp(uid)).get("/protected");
    expect(res.status).toBe(429);
    expect(res.body.error).toBe("rate_limit_exceeded");
  });

  it("takes the fast path on a warm cache without re-reading Firestore", async () => {
    const uid = "rl-warm-1";
    await request(rateLimitApp(uid)).get("/protected");
    expect(getCalls.get(key(uid, "usage"))).toBe(1);

    await request(rateLimitApp(uid)).get("/protected");
    await flush();
    expect(getCalls.get(key(uid, "usage"))).toBe(1); // no second read
    expect(store.get(key(uid, "usage"))?.dailyRequestCount).toBe(2);
  });

  it("falls back to the slow path once the cached count is within the safety margin", async () => {
    const uid = "rl-margin-1";
    const today = new Date().toISOString().slice(0, 10);
    store.set(key(uid, "usage"), { dayKey: today, dailyRequestCount: 495 });

    await request(rateLimitApp(uid)).get("/protected"); // cold -> 496, cached
    expect(getCalls.get(key(uid, "usage"))).toBe(1);

    await request(rateLimitApp(uid)).get("/protected"); // 496 + margin(10) >= 500 -> slow path again
    expect(getCalls.get(key(uid, "usage"))).toBe(2);
    expect(store.get(key(uid, "usage"))?.dailyRequestCount).toBe(497);
  });

  it("re-reads on a day rollover even with a warm same-value cache", async () => {
    const uid = "rl-rollover-1";
    store.set(key(uid, "usage"), { dayKey: "2000-01-01", dailyRequestCount: 3 });
    await request(rateLimitApp(uid)).get("/protected");
    expect(store.get(key(uid, "usage"))?.dailyRequestCount).toBe(1);
  });

  it("fails open on a Firestore hiccup for a linked account", async () => {
    const uid = "rl-failopen-1";
    failNextGet.add(key(uid, "usage"));
    const res = await request(rateLimitApp(uid, false)).get("/protected");
    expect(res.status).toBe(200);
  });

  it("fails closed (503) on a Firestore hiccup for a guest account", async () => {
    const uid = "rl-failclosed-1";
    failNextGet.add(key(uid, "usage"));
    const res = await request(rateLimitApp(uid, true)).get("/protected");
    expect(res.status).toBe(503);
  });
});

describe("governanceGate", () => {
  it("rejects if req.uid is missing (verifyAuth didn't run first)", async () => {
    const { app } = quotaApp(undefined, true, "recommendation");
    const res = await request(app).get("/protected");
    expect(res.status).toBe(401);
  });

  it("allows a guest recommendation request under the 20/month limit (cold, slow path)", async () => {
    const uid = "gg-guest-1";
    const { app } = quotaApp(uid, true, "recommendation");
    const res = await request(app).get("/protected");
    expect(res.status).toBe(200);
    expect(store.get(key(uid, "usage"))?.recommendationCount).toBe(1);
    expect(store.get(key(uid, "usage"))?.dailyRequestCount).toBe(1);
  });

  it("rejects a guest recommendation request once the 20/month limit is hit", async () => {
    const uid = "gg-guest-2";
    const period = new Date().toISOString().slice(0, 7);
    store.set(key(uid, "usage"), { periodKey: period, recommendationCount: 20, tryOnCount: 0 });
    const { app } = quotaApp(uid, true, "recommendation");
    const res = await request(app).get("/protected");
    expect(res.status).toBe(429);
    expect(res.body.error).toBe("quota_exceeded");
    expect(res.body.limit).toBe(20);
  });

  it("rejects guest try-on with sign_in_required, never touching the counters", async () => {
    const uid = "gg-guest-3";
    const { app } = quotaApp(uid, true, "tryOn");
    const res = await request(app).get("/protected");
    expect(res.status).toBe(403);
    expect(res.body.error).toBe("sign_in_required");
    expect(store.get(key(uid, "usage"))).toBeUndefined();
  });

  it("rejects once the daily request cap is hit even with quota headroom", async () => {
    const uid = "gg-daily-cap-1";
    const today = new Date().toISOString().slice(0, 10);
    const period = new Date().toISOString().slice(0, 7);
    store.set(key(uid, "usage"), {
      dayKey: today,
      dailyRequestCount: 500,
      periodKey: period,
      recommendationCount: 1,
      tryOnCount: 0,
    });
    const { app } = quotaApp(uid, false, "recommendation");
    const res = await request(app).get("/protected");
    expect(res.status).toBe(429);
    expect(res.body.error).toBe("rate_limit_exceeded");
  });

  it("takes the fast path (no transaction) when comfortably under both limits", async () => {
    const uid = "gg-fast-1";
    const today = new Date().toISOString().slice(0, 10);
    const period = new Date().toISOString().slice(0, 7);
    store.set(key(uid, "usage"), {
      dayKey: today,
      dailyRequestCount: 5,
      periodKey: period,
      recommendationCount: 5,
      tryOnCount: 0,
    });

    const { app: app1 } = quotaApp(uid, false, "recommendation");
    await request(app1).get("/protected"); // cold (no cache yet) -> slow path, populates cache
    expect(runTransaction).toHaveBeenCalledTimes(1);

    const { app: app2 } = quotaApp(uid, false, "recommendation");
    await request(app2).get("/protected"); // warm -> fast path, no new transaction
    await flush();
    expect(runTransaction).toHaveBeenCalledTimes(1);
    expect(store.get(key(uid, "usage"))?.recommendationCount).toBe(7);
    expect(store.get(key(uid, "usage"))?.dailyRequestCount).toBe(7);
  });

  it("falls back to the slow path once a warm cache's monthly count nears QUOTA_SAFETY_MARGIN, even with daily headroom", async () => {
    const uid = "gg-slow-quota-1";
    const period = new Date().toISOString().slice(0, 7);
    store.set(key(uid, "usage"), { periodKey: period, recommendationCount: 97, tryOnCount: 0 });

    const { app: app1 } = quotaApp(uid, false, "recommendation");
    await request(app1).get("/protected"); // cold -> 98, cached
    expect(runTransaction).toHaveBeenCalledTimes(1);

    const { app: app2 } = quotaApp(uid, false, "recommendation");
    await request(app2).get("/protected"); // 98 + margin(3) >= 100 -> slow path again
    expect(runTransaction).toHaveBeenCalledTimes(2);
    expect(store.get(key(uid, "usage"))?.recommendationCount).toBe(99);
  });

  it("always takes the slow path on a monthly rollover, regardless of the old count", async () => {
    const uid = "gg-rollover-1";
    store.set(key(uid, "usage"), { periodKey: "2000-01", recommendationCount: 0, tryOnCount: 0 });
    const { app } = quotaApp(uid, false, "recommendation");
    const res = await request(app).get("/protected");
    expect(res.status).toBe(200);
    expect(store.get(key(uid, "usage"))?.recommendationCount).toBe(1);
    expect(runTransaction).toHaveBeenCalledTimes(1);
  });

  it("draws down a purchased credit once the free tier is exhausted (always slow path)", async () => {
    const uid = "gg-purchased-1";
    const period = new Date().toISOString().slice(0, 7);
    store.set(key(uid, "usage"), {
      periodKey: period,
      recommendationCount: 100,
      tryOnCount: 0,
      purchasedRecommendationBalance: 3,
    });
    const { app } = quotaApp(uid, false, "recommendation");
    const res = await request(app).get("/protected");
    expect(res.status).toBe(200);
    expect(store.get(key(uid, "usage"))?.purchasedRecommendationBalance).toBe(2);
    expect(store.get(key(uid, "usage"))?.recommendationCount).toBe(100);
    expect(runTransaction).toHaveBeenCalledTimes(1);
  });

  it("rejects with 429 and purchasedBalance 0 once both free tier and balance are gone", async () => {
    const uid = "gg-purchased-2";
    const period = new Date().toISOString().slice(0, 7);
    store.set(key(uid, "usage"), {
      periodKey: period,
      recommendationCount: 100,
      tryOnCount: 0,
      purchasedRecommendationBalance: 0,
    });
    const { app } = quotaApp(uid, false, "recommendation");
    const res = await request(app).get("/protected");
    expect(res.status).toBe(429);
    expect(res.body.error).toBe("quota_exceeded");
    expect(res.body.purchasedBalance).toBe(0);
  });

  it("never touches the other feature's balance when drawing down", async () => {
    const uid = "gg-purchased-3";
    const period = new Date().toISOString().slice(0, 7);
    store.set(key(uid, "usage"), {
      periodKey: period,
      recommendationCount: 100,
      tryOnCount: 0,
      purchasedRecommendationBalance: 1,
      purchasedTryOnBalance: 7,
    });
    const { app } = quotaApp(uid, false, "recommendation");
    const res = await request(app).get("/protected");
    expect(res.status).toBe(200);
    expect(store.get(key(uid, "usage"))?.purchasedRecommendationBalance).toBe(0);
    expect(store.get(key(uid, "usage"))?.purchasedTryOnBalance).toBe(7);
  });

  it("preserves purchased balances on an ordinary fast-path increment (merge regression)", async () => {
    const uid = "gg-preserve-1";
    const today = new Date().toISOString().slice(0, 10);
    const period = new Date().toISOString().slice(0, 7);
    store.set(key(uid, "usage"), {
      dayKey: today,
      dailyRequestCount: 5,
      periodKey: period,
      recommendationCount: 5,
      tryOnCount: 0,
      purchasedRecommendationBalance: 40,
      purchasedTryOnBalance: 10,
    });

    const { app: app1 } = quotaApp(uid, false, "recommendation");
    await request(app1).get("/protected"); // cold, populates cache incl. balances
    expect(runTransaction).toHaveBeenCalledTimes(1);

    const { app: app2 } = quotaApp(uid, false, "recommendation");
    await request(app2).get("/protected"); // fast path, no new transaction
    await flush();

    expect(runTransaction).toHaveBeenCalledTimes(1);
    expect(store.get(key(uid, "usage"))?.recommendationCount).toBe(7);
    expect(store.get(key(uid, "usage"))?.purchasedRecommendationBalance).toBe(40);
    expect(store.get(key(uid, "usage"))?.purchasedTryOnBalance).toBe(10);
  });

  it("resets monthly counts on rollover but always carries purchased balances", async () => {
    const uid = "gg-rollover-2";
    store.set(key(uid, "usage"), {
      periodKey: "2000-01",
      recommendationCount: 100,
      tryOnCount: 10,
      purchasedRecommendationBalance: 12,
      purchasedTryOnBalance: 4,
    });
    const { app } = quotaApp(uid, false, "recommendation");
    const res = await request(app).get("/protected");
    expect(res.status).toBe(200);
    expect(store.get(key(uid, "usage"))?.recommendationCount).toBe(1);
    expect(store.get(key(uid, "usage"))?.tryOnCount).toBe(0);
    expect(store.get(key(uid, "usage"))?.purchasedRecommendationBalance).toBe(12);
    expect(store.get(key(uid, "usage"))?.purchasedTryOnBalance).toBe(4);
  });

  it("falls back to the slow path once a warm cache's daily count nears the daily cap, even with quota headroom", async () => {
    const uid = "gg-daily-margin-1";
    const today = new Date().toISOString().slice(0, 10);
    const period = new Date().toISOString().slice(0, 7);
    store.set(key(uid, "usage"), {
      dayKey: today,
      dailyRequestCount: 495,
      periodKey: period,
      recommendationCount: 1,
      tryOnCount: 0,
    });

    const { app: app1 } = quotaApp(uid, false, "recommendation");
    await request(app1).get("/protected"); // cold -> daily 496, cached
    expect(runTransaction).toHaveBeenCalledTimes(1);

    const { app: app2 } = quotaApp(uid, false, "recommendation");
    await request(app2).get("/protected"); // 496 + margin(10) >= 500 -> slow path again
    expect(runTransaction).toHaveBeenCalledTimes(2);
  });

  it("re-reads once the warm-instance cache TTL expires", async () => {
    // Fake only `Date` — faking timers wholesale would also fake the
    // setTimeout/net internals supertest's HTTP client relies on.
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date("2026-07-21T12:00:00.000Z"));

    const uid = "gg-ttl-1";
    store.set(key(uid, "usage"), {
      dayKey: "2026-07-21",
      dailyRequestCount: 5,
      periodKey: "2026-07",
      recommendationCount: 5,
      tryOnCount: 0,
    });

    const { app: app1 } = quotaApp(uid, false, "recommendation");
    await request(app1).get("/protected"); // cold
    expect(runTransaction).toHaveBeenCalledTimes(1);

    vi.setSystemTime(new Date("2026-07-21T12:00:21.000Z")); // +21s, past the 20s TTL

    const { app: app2 } = quotaApp(uid, false, "recommendation");
    await request(app2).get("/protected");
    expect(runTransaction).toHaveBeenCalledTimes(2);
  });

  it("fails open on a Firestore hiccup for a linked account", async () => {
    const uid = "gg-failopen-1";
    failNextGet.add(key(uid, "usage"));
    const { app } = quotaApp(uid, false, "recommendation");
    const res = await request(app).get("/protected");
    expect(res.status).toBe(200);
  });

  it("fails closed (503) on a Firestore hiccup for a guest account", async () => {
    const uid = "gg-failclosed-1";
    failNextGet.add(key(uid, "usage"));
    const { app } = quotaApp(uid, true, "recommendation");
    const res = await request(app).get("/protected");
    expect(res.status).toBe(503);
  });

  it("sets req.quotaDebit on a successful debit so idempotency.ts can refund it", async () => {
    const uid = "gg-debit-1";
    const { app, getReq } = quotaApp(uid, false, "tryOn");
    await request(app).get("/protected");
    expect(getReq()?.quotaDebit).toEqual({ feature: "tryOn", kind: "count" });
  });
});

describe("refundQuota", () => {
  it("decrements a count debit", async () => {
    const uid = "refund-1";
    store.set(key(uid, "usage"), { periodKey: new Date().toISOString().slice(0, 7), recommendationCount: 5 });
    const req = { uid, quotaDebit: { feature: "recommendation" as const, kind: "count" as const } } as AuthedRequest;
    await refundQuota(req);
    expect(store.get(key(uid, "usage"))?.recommendationCount).toBe(4);
    expect(req.quotaDebit).toBeUndefined();
  });

  it("restores a purchased-balance debit", async () => {
    const uid = "refund-2";
    store.set(key(uid, "usage"), { purchasedRecommendationBalance: 2 });
    const req = { uid, quotaDebit: { feature: "recommendation" as const, kind: "purchased" as const } } as AuthedRequest;
    await refundQuota(req);
    expect(store.get(key(uid, "usage"))?.purchasedRecommendationBalance).toBe(3);
  });

  it("is a no-op when there is no debit to refund", async () => {
    const req = { uid: "refund-3" } as AuthedRequest;
    await expect(refundQuota(req)).resolves.toBeUndefined();
  });

  it("invalidates the cache so the next request re-reads from Firestore", async () => {
    const uid = "refund-4";
    const today = new Date().toISOString().slice(0, 10);
    const period = new Date().toISOString().slice(0, 7);
    store.set(key(uid, "usage"), {
      dayKey: today,
      dailyRequestCount: 5,
      periodKey: period,
      recommendationCount: 5,
      tryOnCount: 0,
    });

    const { app } = quotaApp(uid, false, "recommendation");
    await request(app).get("/protected"); // cold -> slow path, populates cache
    expect(runTransaction).toHaveBeenCalledTimes(1);

    const req = { uid, quotaDebit: { feature: "recommendation" as const, kind: "count" as const } } as AuthedRequest;
    await refundQuota(req);

    const { app: app2 } = quotaApp(uid, false, "recommendation");
    await request(app2).get("/protected"); // cache invalidated -> slow path again
    expect(runTransaction).toHaveBeenCalledTimes(2);
  });
});
