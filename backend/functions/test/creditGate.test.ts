import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";
import express from "express";
import request from "supertest";
import type { AuthedRequest } from "../src/types";

type DocKind = "usage" | "entitlement";

let store: Map<string, Record<string, unknown> | undefined>;
let failNextGet: Set<string>;
let pricingDoc: Record<string, unknown> | undefined;

function key(uid: string, kind: DocKind): string {
  return `${uid}:${kind}`;
}

// Mirrors Firestore's FieldValue.increment: faked as a sentinel object a
// `set` interprets by adding to the field's existing (possibly dotted-path
// nested, e.g. "usage_counts.RECOMMENDATION") value.
function resolveFieldValue(existing: Record<string, unknown> | undefined, path: string, value: unknown): unknown {
  if (value && typeof value === "object" && "__increment" in (value as Record<string, unknown>)) {
    let current: unknown = existing;
    for (const part of path.split(".")) {
      current = current && typeof current === "object" ? (current as Record<string, unknown>)[part] : undefined;
    }
    return ((current as number) ?? 0) + (value as { __increment: number }).__increment;
  }
  return value;
}

// Mirrors Firestore's merge semantics, including its support for a single
// level of dotted-path nested field updates (e.g. "usage_counts.IMAGE_GEN")
// without overwriting sibling keys under the same parent — real Firestore
// `set(..., {merge: true})` supports this natively; this mock only needs
// one level of nesting since that's all `creditGate.ts`/`refundCredit` use.
function applySet(
  existing: Record<string, unknown> | undefined,
  data: Record<string, unknown>,
  merge: boolean | undefined
): Record<string, unknown> {
  const base: Record<string, unknown> = merge ? { ...(existing ?? {}) } : {};
  for (const [path, value] of Object.entries(data)) {
    const resolved = resolveFieldValue(existing, path, value);
    const [outer, ...rest] = path.split(".");
    if (rest.length === 0) {
      base[outer] = resolved;
      continue;
    }
    const existingOuter = (existing?.[outer] as Record<string, unknown> | undefined) ?? {};
    const baseOuter = { ...((base[outer] as Record<string, unknown> | undefined) ?? existingOuter) };
    baseOuter[rest.join(".")] = resolved;
    base[outer] = baseOuter;
  }
  return base;
}

function makeUserRef(uid: string, kind: DocKind) {
  const k = key(uid, kind);
  return {
    get: async () => {
      if (failNextGet.has(k)) {
        failNextGet.delete(k);
        throw new Error("boom");
      }
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
    get: async (ref: ReturnType<typeof makeUserRef>) => ref.get(),
    set: (ref: ReturnType<typeof makeUserRef>, data: Record<string, unknown>, options?: { merge?: boolean }) => {
      void ref.set(data, options);
    },
  };
  return fn(tx);
});

vi.mock("firebase-admin/firestore", () => ({
  getFirestore: () => ({
    collection: (name: string) => {
      if (name === "config") {
        return {
          doc: () => ({
            get: async () => ({ exists: pricingDoc !== undefined, data: () => pricingDoc }),
          }),
        };
      }
      return {
        doc: (uid: string) => ({
          collection: () => ({
            doc: (metaName: DocKind) => makeUserRef(uid, metaName),
          }),
        }),
      };
    },
    runTransaction,
  }),
  FieldValue: {
    increment: (n: number) => ({ __increment: n }),
  },
}));

/**
 * pricing.config.ts's cache is a module-scope singleton — reset modules and
 * dynamically re-import creditGate.ts (which transitively re-imports a
 * fresh pricing.config.ts and governance.ts) so every test starts with an
 * empty cache and re-reads `pricingDoc` fresh.
 */
async function freshModule() {
  vi.resetModules();
  return import("../src/middleware/creditGate");
}

function creditApp(
  uid: string | undefined,
  isAnonymous: boolean,
  operation: "UPLOAD" | "IMAGE_GEN" | "RECOMMENDATION",
  gate: (op: typeof operation) => express.RequestHandler
) {
  const app = express();
  let capturedReq: AuthedRequest | undefined;
  app.use((req: AuthedRequest, _res, next) => {
    req.uid = uid;
    req.isAnonymous = isAnonymous;
    req.requestId = "test-request";
    capturedReq = req;
    next();
  });
  app.use(gate(operation));
  app.get("/protected", (_req, res) => res.status(200).json({ ok: true }));
  return { app, getReq: () => capturedReq };
}

beforeEach(() => {
  store = new Map();
  failNextGet = new Set();
  pricingDoc = undefined;
  runTransaction.mockClear();
});

afterEach(() => {
  vi.useRealTimers();
});

describe("creditGate", () => {
  it("rejects if req.uid is missing (verifyAuth didn't run first)", async () => {
    const { creditGate } = await freshModule();
    const { app } = creditApp(undefined, true, "RECOMMENDATION", creditGate);
    const res = await request(app).get("/protected");
    expect(res.status).toBe(401);
  });

  it("initializes a fresh linked account as FREE with FREE's full allocation", async () => {
    const { creditGate } = await freshModule();
    const uid = "cg-fresh-free-1";
    const { app } = creditApp(uid, false, "RECOMMENDATION", creditGate);
    const res = await request(app).get("/protected");
    expect(res.status).toBe(200);
    expect(store.get(key(uid, "usage"))?.tier_id).toBe("FREE");
    expect(store.get(key(uid, "usage"))?.subscription_credits_remaining).toBe(99); // 100 - cost(1)
    expect(store.get(key(uid, "usage"))?.purchased_credits_remaining).toBe(0);
    expect(store.get(key(uid, "usage"))?.welcome_pack_claimed).toBe(true);
  });

  it("initializes a fresh anonymous account as GUEST", async () => {
    const { creditGate } = await freshModule();
    const uid = "cg-fresh-guest-1";
    const { app } = creditApp(uid, true, "RECOMMENDATION", creditGate);
    const res = await request(app).get("/protected");
    expect(res.status).toBe(200);
    expect(store.get(key(uid, "usage"))?.tier_id).toBe("GUEST");
  });

  it("blocks GUEST from IMAGE_GEN via the hard cap, even though the credit balance is nonzero", async () => {
    const { creditGate } = await freshModule();
    const uid = "cg-guest-cap-1";
    const { app } = creditApp(uid, true, "IMAGE_GEN", creditGate);
    const res = await request(app).get("/protected");
    expect(res.status).toBe(429);
    expect(res.body.error).toBe("cap_reached");
    // Rejected requests write nothing — same minimalism as the old governanceGate.
    expect(store.get(key(uid, "usage"))).toBeUndefined();
  });

  it("rejects with insufficient_credits once the combined balance is below the operation's cost, without debiting", async () => {
    const { creditGate } = await freshModule();
    const uid = "cg-insufficient-1";
    store.set(key(uid, "usage"), {
      tier_id: "FREE",
      subscription_credits_remaining: 0,
      purchased_credits_remaining: 0,
      billing_cycle_start: Date.now(),
      usage_counts: { UPLOAD: 0, IMAGE_GEN: 0, RECOMMENDATION: 0 },
      welcome_pack_claimed: true,
    });
    const { app } = creditApp(uid, false, "RECOMMENDATION", creditGate);
    const res = await request(app).get("/protected");
    expect(res.status).toBe(429);
    expect(res.body.error).toBe("insufficient_credits");
    expect(store.get(key(uid, "usage"))?.subscription_credits_remaining).toBe(0);
    expect(store.get(key(uid, "usage"))?.purchased_credits_remaining).toBe(0);
  });

  it("debits exactly the operation's cost and increments usage_counts on success", async () => {
    const { creditGate } = await freshModule();
    const uid = "cg-debit-1";
    store.set(key(uid, "usage"), {
      tier_id: "FREE",
      subscription_credits_remaining: 100,
      purchased_credits_remaining: 0,
      billing_cycle_start: Date.now(),
      usage_counts: { UPLOAD: 0, IMAGE_GEN: 0, RECOMMENDATION: 3 },
      welcome_pack_claimed: true,
    });
    const { app, getReq } = creditApp(uid, false, "RECOMMENDATION", creditGate);
    const res = await request(app).get("/protected");
    expect(res.status).toBe(200);
    expect(store.get(key(uid, "usage"))?.subscription_credits_remaining).toBe(99);
    expect(store.get(key(uid, "usage"))?.purchased_credits_remaining).toBe(0);
    expect((store.get(key(uid, "usage"))?.usage_counts as Record<string, number>).RECOMMENDATION).toBe(4);
    expect(getReq()?.quotaDebit).toEqual({ operation: "RECOMMENDATION", subscriptionDebited: 1, purchasedDebited: 0 });
  });

  it("draws from subscription credits first, then purchased credits for the remainder (split wallet)", async () => {
    pricingDoc = {
      operationCosts: { UPLOAD: 0, IMAGE_GEN: 5, RECOMMENDATION: 20 },
      tierConfigs: {
        FREE: {
          id: "FREE",
          displayName: "Free",
          monthlyPriceCents: 0,
          creditAllocation: 100,
          autoReset: false,
          itemCap: { core: 10, accessory: 4 },
        },
      },
    };
    const { creditGate } = await freshModule();
    const uid = "cg-splitwallet-1";
    store.set(key(uid, "usage"), {
      tier_id: "FREE",
      subscription_credits_remaining: 10,
      purchased_credits_remaining: 50,
      billing_cycle_start: Date.now(),
      usage_counts: { UPLOAD: 0, IMAGE_GEN: 0, RECOMMENDATION: 0 },
      welcome_pack_claimed: true,
    });
    const { app, getReq } = creditApp(uid, false, "RECOMMENDATION", creditGate);
    const res = await request(app).get("/protected");
    expect(res.status).toBe(200);
    const usage = store.get(key(uid, "usage"));
    expect(usage?.subscription_credits_remaining).toBe(0);
    expect(usage?.purchased_credits_remaining).toBe(40);
    expect(getReq()?.quotaDebit).toEqual({ operation: "RECOMMENDATION", subscriptionDebited: 10, purchasedDebited: 10 });
  });

  it("migrates a legacy pre-rewrite doc (no tier_id) into the new schema, carrying purchased balances across as fungible credits", async () => {
    const { creditGate } = await freshModule();
    const uid = "cg-migrate-1";
    store.set(key(uid, "usage"), {
      periodKey: "2026-06",
      recommendationCount: 100, // FREE's old limit fully used
      tryOnCount: 10, // FREE's old tryOn limit fully used
      purchasedRecommendationBalance: 7,
      purchasedTryOnBalance: 3,
    });
    const { app } = creditApp(uid, false, "RECOMMENDATION", creditGate);
    const res = await request(app).get("/protected");
    expect(res.status).toBe(200);
    const usage = store.get(key(uid, "usage"));
    expect(usage?.tier_id).toBe("FREE");
    // No headroom left on the old counters (0 derived), so
    // subscription_credits_remaining floors at FREE's allocation (100), then
    // debited by this request's cost (1). The old purchased balance (7+3=10)
    // carries across untouched into purchased_credits_remaining — kept
    // separate from the floor so it's never silently absorbed by it.
    expect(usage?.subscription_credits_remaining).toBe(99);
    expect(usage?.purchased_credits_remaining).toBe(10);
    expect(usage?.welcome_pack_claimed).toBe(true);
  });

  it("migrates a legacy doc with unused headroom into a larger starting balance than the tier floor", async () => {
    const { creditGate } = await freshModule();
    const uid = "cg-migrate-2";
    store.set(key(uid, "usage"), {
      periodKey: "2026-06",
      recommendationCount: 0,
      tryOnCount: 0,
      purchasedRecommendationBalance: 0,
      purchasedTryOnBalance: 0,
    });
    store.set(key(uid, "entitlement"), { tier: "premium" });
    const { app } = creditApp(uid, false, "RECOMMENDATION", creditGate);
    const res = await request(app).get("/protected");
    expect(res.status).toBe(200);
    const usage = store.get(key(uid, "usage"));
    expect(usage?.tier_id).toBe("PRO");
    // Full legacy PRO(premium) headroom: 500 unused recommendations * cost(1)
    // + 100 unused tryOn * cost(5) = 1000, floored at PRO's own allocation
    // (500) -> 1000 is larger, so subscription_credits_remaining =
    // 1000 - cost(1) = 999. No legacy purchased balance in this fixture.
    expect(usage?.subscription_credits_remaining).toBe(999);
    expect(usage?.purchased_credits_remaining).toBe(0);
  });

  it("resets a recurring (autoReset) tier's subscription credits at the billing anniversary, leaving purchased credits untouched", async () => {
    const { creditGate } = await freshModule();
    const uid = "cg-reset-1";
    const past = Date.UTC(2026, 0, 1); // Jan 1 2026, well over a month ago
    store.set(key(uid, "usage"), {
      tier_id: "PRO",
      subscription_credits_remaining: 3,
      purchased_credits_remaining: 40,
      billing_cycle_start: past,
      usage_counts: { UPLOAD: 0, IMAGE_GEN: 10, RECOMMENDATION: 10 },
      welcome_pack_claimed: true,
    });
    const { app } = creditApp(uid, false, "RECOMMENDATION", creditGate);
    const res = await request(app).get("/protected");
    expect(res.status).toBe(200);
    const usage = store.get(key(uid, "usage"));
    expect(usage?.subscription_credits_remaining).toBe(499); // 500 (PRO allocation) - cost(1)
    expect(usage?.purchased_credits_remaining).toBe(40); // never touched by autoReset (Apple IAP compliance)
    expect((usage?.usage_counts as Record<string, number>).RECOMMENDATION).toBe(1); // zeroed then incremented
    expect(usage?.billing_cycle_start).not.toBe(past);
  });

  it("never auto-resets a non-recurring tier (FREE) even if billing_cycle_start looks stale", async () => {
    const { creditGate } = await freshModule();
    const uid = "cg-noreset-1";
    const past = Date.UTC(2026, 0, 1);
    store.set(key(uid, "usage"), {
      tier_id: "FREE",
      subscription_credits_remaining: 2,
      purchased_credits_remaining: 0,
      billing_cycle_start: past,
      usage_counts: { UPLOAD: 0, IMAGE_GEN: 0, RECOMMENDATION: 5 },
      welcome_pack_claimed: true,
    });
    const { app } = creditApp(uid, false, "RECOMMENDATION", creditGate);
    const res = await request(app).get("/protected");
    expect(res.status).toBe(200);
    expect(store.get(key(uid, "usage"))?.subscription_credits_remaining).toBe(1); // 2 - cost(1), NOT refilled to 100
  });

  it("fails open on a Firestore hiccup for a linked account", async () => {
    const { creditGate } = await freshModule();
    const uid = "cg-failopen-1";
    failNextGet.add(key(uid, "usage"));
    const { app } = creditApp(uid, false, "RECOMMENDATION", creditGate);
    const res = await request(app).get("/protected");
    expect(res.status).toBe(200);
  });

  it("fails closed (503) on a Firestore hiccup for a guest account", async () => {
    const { creditGate } = await freshModule();
    const uid = "cg-failclosed-1";
    failNextGet.add(key(uid, "usage"));
    const { app } = creditApp(uid, true, "RECOMMENDATION", creditGate);
    const res = await request(app).get("/protected");
    expect(res.status).toBe(503);
  });

  /**
   * Required proof #1: mutating the (mocked) config/pricing doc's
   * operationCosts changes gatekeeper behavior with zero code changes.
   */
  it("honors a config-driven operation cost change with no code change", async () => {
    pricingDoc = {
      operationCosts: { UPLOAD: 0, IMAGE_GEN: 5, RECOMMENDATION: 50 }, // RECOMMENDATION now costs 50
      tierConfigs: {
        FREE: {
          id: "FREE",
          displayName: "Free",
          monthlyPriceCents: 0,
          creditAllocation: 100,
          autoReset: false,
          itemCap: { core: 10, accessory: 4 },
        },
      },
    };
    const { creditGate } = await freshModule();
    const uid = "cg-config-cost-1";
    store.set(key(uid, "usage"), {
      tier_id: "FREE",
      subscription_credits_remaining: 40, // below the new cost of 50
      purchased_credits_remaining: 0,
      billing_cycle_start: Date.now(),
      usage_counts: { UPLOAD: 0, IMAGE_GEN: 0, RECOMMENDATION: 0 },
      welcome_pack_claimed: true,
    });
    const { app } = creditApp(uid, false, "RECOMMENDATION", creditGate);
    const res = await request(app).get("/protected");
    expect(res.status).toBe(429);
    expect(res.body.error).toBe("insufficient_credits");
    expect(res.body.cost).toBe(50);
  });

  /**
   * Required proof #2: a brand-new tier defined ONLY in the (mocked)
   * config/pricing doc is fully supported by the gatekeeper, no code change.
   */
  it("supports a dynamically-added tier (ULTRA_PRO) defined only in config, no code change", async () => {
    pricingDoc = {
      operationCosts: { UPLOAD: 0, IMAGE_GEN: 5, RECOMMENDATION: 1 },
      tierConfigs: {
        FREE: {
          id: "FREE",
          displayName: "Free",
          monthlyPriceCents: 0,
          creditAllocation: 100,
          autoReset: false,
          itemCap: { core: 10, accessory: 4 },
        },
        ULTRA_PRO: {
          id: "ULTRA_PRO",
          displayName: "Ultra Pro",
          monthlyPriceCents: 2999,
          creditAllocation: 5000,
          autoReset: true,
          hardCaps: { IMAGE_GEN: 1000 },
          itemCap: { core: 200, accessory: 200 },
        },
      },
    };
    const { creditGate } = await freshModule();
    const uid = "cg-ultrapro-1";
    store.set(key(uid, "usage"), {
      tier_id: "ULTRA_PRO",
      subscription_credits_remaining: 4000,
      purchased_credits_remaining: 0,
      billing_cycle_start: Date.now(),
      usage_counts: { UPLOAD: 0, IMAGE_GEN: 999, RECOMMENDATION: 0 },
      welcome_pack_claimed: true,
    });
    const { app } = creditApp(uid, false, "IMAGE_GEN", creditGate);
    const res = await request(app).get("/protected");
    expect(res.status).toBe(200);
    expect(store.get(key(uid, "usage"))?.subscription_credits_remaining).toBe(3995); // 4000 - cost(5)

    // One more IMAGE_GEN call hits ULTRA_PRO's own hard cap (1000).
    const { app: app2 } = creditApp(uid, false, "IMAGE_GEN", creditGate);
    const res2 = await request(app2).get("/protected");
    expect(res2.status).toBe(429);
    expect(res2.body.error).toBe("cap_reached");
  });
});

describe("refundCredit", () => {
  it("restores a subscription-only debit to subscription_credits_remaining and decrements the usage counter", async () => {
    const { refundCredit } = await freshModule();
    const uid = "refund-1";
    store.set(key(uid, "usage"), {
      subscription_credits_remaining: 95,
      purchased_credits_remaining: 10,
      usage_counts: { UPLOAD: 0, IMAGE_GEN: 0, RECOMMENDATION: 4 },
    });
    const req = {
      uid,
      requestId: "r",
      quotaDebit: { operation: "RECOMMENDATION" as const, subscriptionDebited: 1, purchasedDebited: 0 },
    } as AuthedRequest;
    await refundCredit(req);
    expect(store.get(key(uid, "usage"))?.subscription_credits_remaining).toBe(96);
    expect(store.get(key(uid, "usage"))?.purchased_credits_remaining).toBe(10); // untouched
    expect((store.get(key(uid, "usage"))?.usage_counts as Record<string, number>).RECOMMENDATION).toBe(3);
    expect(req.quotaDebit).toBeUndefined();
  });

  it("restores a split debit to the exact buckets it was drawn from", async () => {
    const { refundCredit } = await freshModule();
    const uid = "refund-2";
    store.set(key(uid, "usage"), {
      subscription_credits_remaining: 0,
      purchased_credits_remaining: 44,
      usage_counts: { UPLOAD: 0, IMAGE_GEN: 0, RECOMMENDATION: 4 },
    });
    const req = {
      uid,
      requestId: "r",
      quotaDebit: { operation: "RECOMMENDATION" as const, subscriptionDebited: 0, purchasedDebited: 1 },
    } as AuthedRequest;
    await refundCredit(req);
    expect(store.get(key(uid, "usage"))?.subscription_credits_remaining).toBe(0); // untouched
    expect(store.get(key(uid, "usage"))?.purchased_credits_remaining).toBe(45);
    expect((store.get(key(uid, "usage"))?.usage_counts as Record<string, number>).RECOMMENDATION).toBe(3);
    expect(req.quotaDebit).toBeUndefined();
  });

  it("is a no-op when there is no debit to refund", async () => {
    const { refundCredit } = await freshModule();
    const req = { uid: "refund-3" } as AuthedRequest;
    await expect(refundCredit(req)).resolves.toBeUndefined();
  });
});
