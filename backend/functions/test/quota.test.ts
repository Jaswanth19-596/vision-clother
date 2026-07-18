import { describe, expect, it, vi, beforeEach } from "vitest";
import express from "express";
import request from "supertest";
import type { AuthedRequest } from "../src/types";

let usageDoc: Record<string, unknown> | undefined;
let entitlementDoc: Record<string, unknown> | undefined;

type DocKind = "usage" | "entitlement";

function currentDoc(kind: DocKind): Record<string, unknown> | undefined {
  return kind === "usage" ? usageDoc : entitlementDoc;
}

function writeDoc(kind: DocKind, next: Record<string, unknown>): void {
  if (kind === "usage") {
    usageDoc = next;
  } else {
    entitlementDoc = next;
  }
}

// Mirrors Firestore's FieldValue.increment: quota.ts's fast path uses it
// directly (no transaction), the slow path's transaction still uses plain
// values. Faked as a sentinel object a `set` interprets by adding to the
// field's existing value.
function resolveFieldValue(existing: Record<string, unknown> | undefined, key: string, value: unknown): unknown {
  if (value && typeof value === "object" && "__increment" in (value as Record<string, unknown>)) {
    const current = (existing?.[key] as number) ?? 0;
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
  for (const [key, value] of Object.entries(data)) {
    resolved[key] = resolveFieldValue(existing, key, value);
  }
  return merge ? { ...(existing ?? {}), ...resolved } : resolved;
}

// A single ref implementation backs both the transactional (tx.get/tx.set)
// and non-transactional (ref.get/ref.set) call shapes quota.ts now uses, so
// the fast and slow paths share the same fake Firestore state.
function makeRef(kind: DocKind) {
  return {
    kind,
    get: async () => {
      const data = currentDoc(kind);
      return { exists: data !== undefined, data: () => data };
    },
    set: async (data: Record<string, unknown>, options?: { merge?: boolean }) => {
      writeDoc(kind, applySet(currentDoc(kind), data, options?.merge));
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
      doc: () => ({
        collection: () => ({
          doc: (name: DocKind) => makeRef(name),
        }),
      }),
    }),
    runTransaction,
  }),
  FieldValue: {
    increment: (n: number) => ({ __increment: n }),
  },
}));

import { quotaGate } from "../src/middleware/quota";

function appWith(uid: string | undefined, isAnonymous: boolean, feature: "recommendation" | "tryOn") {
  const app = express();
  app.use((req: AuthedRequest, _res, next) => {
    req.uid = uid;
    req.isAnonymous = isAnonymous;
    next();
  });
  app.use(quotaGate(feature));
  app.get("/protected", (_req, res) => res.status(200).json({ ok: true }));
  return app;
}

beforeEach(() => {
  usageDoc = undefined;
  entitlementDoc = undefined;
  runTransaction.mockClear();
});

describe("quotaGate", () => {
  it("rejects if req.uid is missing (verifyAuth didn't run first)", async () => {
    const app = appWith(undefined, true, "recommendation");
    const res = await request(app).get("/protected");
    expect(res.status).toBe(401);
  });

  it("allows a guest recommendation request under the 20/month limit", async () => {
    const app = appWith("guest-1", true, "recommendation");
    const res = await request(app).get("/protected");
    expect(res.status).toBe(200);
    expect(usageDoc?.recommendationCount).toBe(1);
  });

  it("rejects a guest recommendation request once the 20/month limit is hit", async () => {
    usageDoc = { periodKey: new Date().toISOString().slice(0, 7), recommendationCount: 20, tryOnCount: 0 };
    const app = appWith("guest-1", true, "recommendation");
    const res = await request(app).get("/protected");
    expect(res.status).toBe(429);
    expect(res.body.error).toBe("quota_exceeded");
    expect(res.body.limit).toBe(20);
  });

  it("rejects guest try-on with a distinct sign_in_required error, never touching the counter", async () => {
    const app = appWith("guest-1", true, "tryOn");
    const res = await request(app).get("/protected");
    expect(res.status).toBe(403);
    expect(res.body.error).toBe("sign_in_required");
    expect(usageDoc).toBeUndefined();
  });

  it("allows a signed-in free-tier try-on request under the 10/month limit", async () => {
    const app = appWith("free-1", false, "tryOn");
    const res = await request(app).get("/protected");
    expect(res.status).toBe(200);
    expect(usageDoc?.tryOnCount).toBe(1);
  });

  it("rejects a signed-in free-tier recommendation request once the 100/month limit is hit", async () => {
    usageDoc = { periodKey: new Date().toISOString().slice(0, 7), recommendationCount: 100, tryOnCount: 0 };
    const app = appWith("free-1", false, "recommendation");
    const res = await request(app).get("/protected");
    expect(res.status).toBe(429);
    expect(res.body.limit).toBe(100);
  });

  it("lazily resets the counter when the stored period is a prior month", async () => {
    usageDoc = { periodKey: "2000-01", recommendationCount: 100, tryOnCount: 10 };
    const app = appWith("free-1", false, "recommendation");
    const res = await request(app).get("/protected");
    expect(res.status).toBe(200);
    expect(usageDoc?.recommendationCount).toBe(1);
    expect(usageDoc?.tryOnCount).toBe(0);
  });

  it("fails open on a Firestore hiccup", async () => {
    runTransaction.mockRejectedValueOnce(new Error("boom"));
    const app = appWith("free-1", false, "recommendation");
    const res = await request(app).get("/protected");
    expect(res.status).toBe(200);
  });

  // Fast path / slow path split (non-transactional FieldValue.increment vs
  // the transaction), gated by QUOTA_SAFETY_MARGIN and period rollover.

  it("takes the fast path (no transaction) when comfortably under the limit", async () => {
    usageDoc = { periodKey: new Date().toISOString().slice(0, 7), recommendationCount: 5, tryOnCount: 0 };
    const app = appWith("free-1", false, "recommendation");
    const res = await request(app).get("/protected");
    expect(res.status).toBe(200);
    expect(usageDoc?.recommendationCount).toBe(6);
    expect(runTransaction).not.toHaveBeenCalled();
  });

  it("takes the slow path (transaction) once within QUOTA_SAFETY_MARGIN of the limit", async () => {
    usageDoc = { periodKey: new Date().toISOString().slice(0, 7), recommendationCount: 98, tryOnCount: 0 };
    const app = appWith("free-1", false, "recommendation");
    const res = await request(app).get("/protected");
    expect(res.status).toBe(200);
    expect(usageDoc?.recommendationCount).toBe(99);
    expect(runTransaction).toHaveBeenCalledTimes(1);
  });

  it("always takes the slow path on a period rollover, regardless of the old count", async () => {
    usageDoc = { periodKey: "2000-01", recommendationCount: 0, tryOnCount: 0 };
    const app = appWith("free-1", false, "recommendation");
    const res = await request(app).get("/protected");
    expect(res.status).toBe(200);
    expect(usageDoc?.recommendationCount).toBe(1);
    expect(runTransaction).toHaveBeenCalledTimes(1);
  });

  // Purchased-credit drawdown (StoreKit top-ups — routes/iapVerify.ts grants,
  // this middleware spends): free tier first, then the lifetime balance.
  // All at-cap, so all exercise the slow path/transaction.

  it("draws down a purchased credit once the free tier is exhausted", async () => {
    usageDoc = {
      periodKey: new Date().toISOString().slice(0, 7),
      recommendationCount: 100,
      tryOnCount: 0,
      purchasedRecommendationBalance: 3,
    };
    const app = appWith("free-1", false, "recommendation");
    const res = await request(app).get("/protected");
    expect(res.status).toBe(200);
    expect(usageDoc?.purchasedRecommendationBalance).toBe(2);
    // The monthly counter must NOT advance past its cap on the drawdown path.
    expect(usageDoc?.recommendationCount).toBe(100);
  });

  it("rejects with 429 and purchasedBalance 0 once both free tier and balance are gone", async () => {
    usageDoc = {
      periodKey: new Date().toISOString().slice(0, 7),
      recommendationCount: 100,
      tryOnCount: 0,
      purchasedRecommendationBalance: 0,
    };
    const app = appWith("free-1", false, "recommendation");
    const res = await request(app).get("/protected");
    expect(res.status).toBe(429);
    expect(res.body.error).toBe("quota_exceeded");
    expect(res.body.purchasedBalance).toBe(0);
  });

  it("never touches the other feature's balance when drawing down", async () => {
    usageDoc = {
      periodKey: new Date().toISOString().slice(0, 7),
      recommendationCount: 100,
      tryOnCount: 0,
      purchasedRecommendationBalance: 1,
      purchasedTryOnBalance: 7,
    };
    const app = appWith("free-1", false, "recommendation");
    const res = await request(app).get("/protected");
    expect(res.status).toBe(200);
    expect(usageDoc?.purchasedRecommendationBalance).toBe(0);
    expect(usageDoc?.purchasedTryOnBalance).toBe(7);
  });

  it("preserves purchased balances on an ordinary under-limit increment (fast-path merge regression)", async () => {
    usageDoc = {
      periodKey: new Date().toISOString().slice(0, 7),
      recommendationCount: 5,
      tryOnCount: 0,
      purchasedRecommendationBalance: 40,
      purchasedTryOnBalance: 10,
    };
    const app = appWith("free-1", false, "recommendation");
    const res = await request(app).get("/protected");
    expect(res.status).toBe(200);
    expect(usageDoc?.recommendationCount).toBe(6);
    expect(usageDoc?.purchasedRecommendationBalance).toBe(40);
    expect(usageDoc?.purchasedTryOnBalance).toBe(10);
    expect(runTransaction).not.toHaveBeenCalled();
  });

  it("resets monthly counts on period rollover but always carries purchased balances", async () => {
    usageDoc = {
      periodKey: "2000-01",
      recommendationCount: 100,
      tryOnCount: 10,
      purchasedRecommendationBalance: 12,
      purchasedTryOnBalance: 4,
    };
    const app = appWith("free-1", false, "recommendation");
    const res = await request(app).get("/protected");
    expect(res.status).toBe(200);
    expect(usageDoc?.recommendationCount).toBe(1);
    expect(usageDoc?.tryOnCount).toBe(0);
    expect(usageDoc?.purchasedRecommendationBalance).toBe(12);
    expect(usageDoc?.purchasedTryOnBalance).toBe(4);
  });

  it("spends the free tier, not the balance, after a rollover even when the old month was capped", async () => {
    usageDoc = {
      periodKey: "2000-01",
      recommendationCount: 100,
      tryOnCount: 0,
      purchasedRecommendationBalance: 5,
    };
    const app = appWith("free-1", false, "recommendation");
    const res = await request(app).get("/protected");
    expect(res.status).toBe(200);
    expect(usageDoc?.recommendationCount).toBe(1);
    expect(usageDoc?.purchasedRecommendationBalance).toBe(5);
  });
});
