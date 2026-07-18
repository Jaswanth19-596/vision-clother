import { describe, expect, it, vi, beforeEach } from "vitest";
import express from "express";
import request from "supertest";
import type { AuthedRequest } from "../src/types";

let storedCount = 0;

const runTransaction = vi.fn();

// Mirrors rateLimit.ts's non-transactional get() + FieldValue.increment set().
// FieldValue.increment is faked as a sentinel object the mock's `set`
// interprets by adding to the existing stored value.
const docRef = {
  get: async () => ({ exists: storedCount > 0, data: () => ({ count: storedCount }) }),
  set: async (data: { count: unknown }) => {
    const value = data.count as { __increment?: number } | number;
    storedCount =
      typeof value === "object" && value !== null && "__increment" in value
        ? storedCount + (value.__increment ?? 0)
        : (value as number);
  },
};

vi.mock("firebase-admin/firestore", () => ({
  getFirestore: () => ({
    collection: () => ({ doc: () => docRef }),
    runTransaction,
  }),
  FieldValue: {
    increment: (n: number) => ({ __increment: n }),
  },
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
  runTransaction.mockClear();
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

  it("never uses a Firestore transaction (non-transactional atomic increment only)", async () => {
    const app = appWithUid("user-1");
    await request(app).get("/protected");
    expect(runTransaction).not.toHaveBeenCalled();
  });
});
