import { describe, expect, it, vi, beforeEach } from "vitest";
import express from "express";
import request from "supertest";
import type { AuthedRequest } from "../src/types";

let storedCount = 0;

const runTransaction = vi.fn(async (fn: (tx: unknown) => Promise<boolean>) => {
  const tx = {
    get: async () => ({ exists: storedCount > 0, data: () => ({ count: storedCount }) }),
    set: (_ref: unknown, data: { count: number }) => {
      storedCount = data.count;
    },
  };
  return fn(tx);
});

vi.mock("firebase-admin/firestore", () => ({
  getFirestore: () => ({
    collection: () => ({ doc: () => ({}) }),
    runTransaction,
  }),
}));

import { rateLimit } from "../src/middleware/rateLimit";

function appWithUid(uid?: string) {
  const app = express();
  app.use((req: AuthedRequest, _res, next) => {
    req.uid = uid;
    next();
  });
  app.use(rateLimit);
  app.get("/protected", (_req, res) => res.status(200).json({ ok: true }));
  return app;
}

beforeEach(() => {
  storedCount = 0;
});

describe("rateLimit", () => {
  it("rejects if req.uid is missing (verifyAuth didn't run first)", async () => {
    const app = appWithUid(undefined);
    const res = await request(app).get("/protected");
    expect(res.status).toBe(401);
  });

  it("allows requests under the daily limit", async () => {
    const app = appWithUid("user-1");
    const res = await request(app).get("/protected");
    expect(res.status).toBe(200);
    expect(storedCount).toBe(1);
  });

  it("rejects once the daily limit is exceeded", async () => {
    storedCount = 500;
    const app = appWithUid("user-1");
    const res = await request(app).get("/protected");
    expect(res.status).toBe(429);
    expect(res.body.error).toBe("rate_limit_exceeded");
  });
});
