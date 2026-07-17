import { describe, expect, it, vi, beforeEach } from "vitest";
import express from "express";
import request from "supertest";
import type { AuthedRequest } from "../src/types";

let usageDoc: Record<string, unknown> | undefined;
let entitlementDoc: Record<string, unknown> | undefined;

function makeRef(kind: "usage" | "entitlement") {
  return { kind };
}

const runTransaction = vi.fn(async (fn: (tx: unknown) => Promise<unknown>) => {
  const tx = {
    get: async (ref: { kind: "usage" | "entitlement" }) => {
      const data = ref.kind === "usage" ? usageDoc : entitlementDoc;
      return { exists: data !== undefined, data: () => data };
    },
    // Mirrors Firestore's merge semantics: `{merge: true}` (what quota.ts
    // now uses — see its field-scoped-write comment) folds into the existing
    // doc; a plain set replaces it.
    set: (ref: { kind: "usage" | "entitlement" }, data: Record<string, unknown>, options?: { merge?: boolean }) => {
      const existing = ref.kind === "usage" ? usageDoc : entitlementDoc;
      const next = options?.merge ? { ...(existing ?? {}), ...data } : data;
      if (ref.kind === "usage") {
        usageDoc = next;
      } else {
        entitlementDoc = next;
      }
    },
  };
  return fn(tx);
});

vi.mock("firebase-admin/firestore", () => ({
  getFirestore: () => ({
    collection: () => ({
      doc: () => ({
        collection: () => ({
          doc: (name: "usage" | "entitlement") => makeRef(name),
        }),
      }),
    }),
    runTransaction,
  }),
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

  // Purchased-credit drawdown (StoreKit top-ups — routes/iapVerify.ts grants,
  // this middleware spends): free tier first, then the lifetime balance.

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

  it("preserves purchased balances on an ordinary under-limit increment (merge regression)", async () => {
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
