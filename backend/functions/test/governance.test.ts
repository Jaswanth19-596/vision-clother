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

vi.mock("firebase-admin/firestore", () => ({
  getFirestore: () => ({
    collection: () => ({
      doc: (uid: string) => ({
        collection: () => ({
          doc: (name: DocKind) => makeRef(uid, name),
        }),
      }),
    }),
  }),
  FieldValue: {
    increment: (n: number) => ({ __increment: n }),
  },
}));

import { rateLimitOnly } from "../src/middleware/governance";

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

// Allow a single microtask tick for `rateLimitOnly`'s fire-and-forget
// (unawaited) Firestore write to land before assertions read `store`.
async function flush(): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, 0));
}

beforeEach(() => {
  store = new Map();
  getCalls = new Map();
  failNextGet = new Set();
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
