import { describe, expect, it, vi, beforeEach } from "vitest";
import express from "express";
import request from "supertest";
import type { AuthedRequest } from "../src/types";
import { responseCache } from "../src/middleware/responseCache";

let store: Map<string, Record<string, unknown> | undefined>;
let failNextUid: Set<string>;

function makeCacheRef(uid: string, cacheKey: string) {
  const k = `${uid}::${cacheKey}`;
  return {
    get: async () => {
      if (failNextUid.has(uid)) {
        failNextUid.delete(uid);
        throw new Error("boom");
      }
      const data = store.get(k);
      return { data: () => data };
    },
    set: async (data: Record<string, unknown>) => {
      store.set(k, data);
    },
  };
}

vi.mock("firebase-admin/firestore", () => ({
  getFirestore: () => ({
    collection: () => ({
      doc: (uid: string) => ({
        collection: () => ({
          doc: (cacheKey: string) => makeCacheRef(uid, cacheKey),
        }),
      }),
    }),
  }),
}));

/**
 * Mirrors app.ts's baseApp(): express.json's `verify` callback captures the
 * raw wire bytes onto req.rawBody, which is what lets responseCache hash the
 * bytes directly instead of falling back to JSON.stringify(req.body). A GET
 * with no body never triggers `verify` (no JSON body to parse), which is
 * exactly the fallback path /analytics/config relies on in production.
 */
function cacheApp(feature: string) {
  const app = express();
  app.use(
    express.json({
      verify: (req, _res, buf) => {
        (req as AuthedRequest).rawBody = buf;
      },
    })
  );
  app.use((req: AuthedRequest, _res, next) => {
    req.uid = "cache-test-uid";
    req.requestId = "test-request";
    next();
  });
  app.use(responseCache(feature));
  let calls = 0;
  app.all("/protected", (_req, res) => {
    calls += 1;
    res.status(200).json({ ok: true, calls });
  });
  return { app, getCalls: () => calls };
}

beforeEach(() => {
  store = new Map();
  failNextUid = new Set();
});

describe("responseCache", () => {
  it("caches a 2xx response and serves it back on an identical request without re-invoking the downstream handler", async () => {
    const { app, getCalls } = cacheApp("recommendation");
    const first = await request(app).post("/protected").send({ scenario: "beach day", weather: "sunny" });
    expect(first.status).toBe(200);
    expect(first.body.calls).toBe(1);

    const second = await request(app).post("/protected").send({ scenario: "beach day", weather: "sunny" });
    expect(second.status).toBe(200);
    expect(second.body.calls).toBe(1); // handler never ran again — served from cache
    expect(getCalls()).toBe(1);
  });

  it("produces different cache keys for different request bodies (no cross-talk)", async () => {
    const { app, getCalls } = cacheApp("recommendation");
    const first = await request(app).post("/protected").send({ scenario: "beach day" });
    const second = await request(app).post("/protected").send({ scenario: "gala night" });
    expect(first.body.calls).toBe(1);
    expect(second.body.calls).toBe(2); // distinct body -> cache miss -> handler ran again
    expect(getCalls()).toBe(2);
  });

  it("falls back to hashing req.body when rawBody is unset (bodyless request, e.g. analytics/config)", async () => {
    const { app, getCalls } = cacheApp("analyticsConfig");
    const first = await request(app).get("/protected");
    expect(first.body.calls).toBe(1);

    const second = await request(app).get("/protected");
    expect(second.body.calls).toBe(1); // still served from cache via the JSON.stringify fallback
    expect(getCalls()).toBe(1);
  });

  it("fails open (still serves the downstream response) on a Firestore lookup error", async () => {
    const { app } = cacheApp("recommendation");
    failNextUid.add("cache-test-uid");
    const res = await request(app).post("/protected").send({ scenario: "beach day" });
    expect(res.status).toBe(200);
    expect(res.body.calls).toBe(1);
  });
});
