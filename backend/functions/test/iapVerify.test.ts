import { describe, expect, it, vi, beforeEach } from "vitest";
import express from "express";
import request from "supertest";
import type { AuthedRequest } from "../src/types";

let usageDoc: Record<string, unknown> | undefined;
let processedDocs: Record<string, Record<string, unknown>>;

type Ref = { kind: "usage" } | { kind: "processed"; id: string };

function readRef(ref: Ref): Record<string, unknown> | undefined {
  return ref.kind === "usage" ? usageDoc : processedDocs[ref.id];
}

function writeRef(ref: Ref, data: Record<string, unknown>, options?: { merge?: boolean }): void {
  const existing = readRef(ref);
  const next = options?.merge ? { ...(existing ?? {}), ...data } : data;
  if (ref.kind === "usage") {
    usageDoc = next;
  } else {
    processedDocs[ref.id] = next;
  }
}

const runTransaction = vi.fn(async (fn: (tx: unknown) => Promise<unknown>) => {
  const tx = {
    get: async (ref: Ref) => {
      const data = readRef(ref);
      return { exists: data !== undefined, data: () => data };
    },
    set: (ref: Ref, data: Record<string, unknown>, options?: { merge?: boolean }) => {
      writeRef(ref, data, options);
    },
  };
  return fn(tx);
});

vi.mock("firebase-admin/firestore", () => ({
  getFirestore: () => ({
    collection: (name: string) => {
      if (name === "processedTransactions") {
        return {
          doc: (id: string) => ({
            kind: "processed" as const,
            id,
            set: async (data: Record<string, unknown>) => writeRef({ kind: "processed", id }, data),
          }),
        };
      }
      // users/{uid}/meta/usage
      return {
        doc: () => ({
          collection: () => ({
            doc: () => ({ kind: "usage" as const }),
          }),
        }),
      };
    },
    runTransaction,
  }),
}));

// The real module imports @apple/app-store-server-library (not installable
// in this test environment) — mock the whole surface, including the error
// class the route type-checks with `instanceof`.
vi.mock("../src/iap/verifyTransaction", () => {
  class IapVerifyError extends Error {
    readonly code: string;
    constructor(code: string, message: string) {
      super(message);
      this.code = code;
      this.name = "IapVerifyError";
    }
  }
  return { IapVerifyError, verifyIapJws: vi.fn() };
});

import { IapVerifyError, verifyIapJws } from "../src/iap/verifyTransaction";
import { iapVerifyRouter } from "../src/routes/iapVerify";

const mockedVerify = vi.mocked(verifyIapJws);

function appWith(uid: string | undefined, isAnonymous: boolean) {
  const app = express();
  app.use(express.json());
  app.use((req: AuthedRequest, _res, next) => {
    req.uid = uid;
    req.isAnonymous = isAnonymous;
    req.requestId = "test-req";
    next();
  });
  app.use("/iap/verify", iapVerifyRouter);
  return app;
}

function verifiedTransaction(overrides: Partial<{
  transactionId: string;
  originalTransactionId: string;
  productId: string;
  purchaseDate: number;
  environment: "Sandbox" | "Production" | "Xcode";
  revoked: boolean;
}> = {}) {
  return {
    transactionId: "2000000123456789",
    originalTransactionId: "2000000123456789",
    productId: "com.visionclother.credits.recs50",
    purchaseDate: 1789030000000,
    environment: "Sandbox" as const,
    revoked: false,
    ...overrides,
  };
}

beforeEach(() => {
  usageDoc = undefined;
  processedDocs = {};
  mockedVerify.mockReset();
});

describe("POST /iap/verify", () => {
  it("rejects when req.uid is missing", async () => {
    const res = await request(appWith(undefined, false)).post("/iap/verify").send({ jws: "x" });
    expect(res.status).toBe(401);
  });

  it("rejects anonymous purchasers before touching the verifier", async () => {
    const res = await request(appWith("guest-1", true)).post("/iap/verify").send({ jws: "x" });
    expect(res.status).toBe(403);
    expect(res.body.error).toBe("sign_in_required");
    expect(mockedVerify).not.toHaveBeenCalled();
  });

  it("rejects a missing/empty jws body", async () => {
    const res = await request(appWith("user-1", false)).post("/iap/verify").send({});
    expect(res.status).toBe(400);
    expect(res.body.error).toBe("invalid_request");
  });

  it("grants credits and writes the idempotency ledger doc on a fresh transaction", async () => {
    mockedVerify.mockResolvedValueOnce(verifiedTransaction());
    const res = await request(appWith("user-1", false)).post("/iap/verify").send({ jws: "signed" });
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ granted: true, creditType: "recommendation", amount: 50, newBalance: 50, alreadyProcessed: false });
    expect(usageDoc?.purchasedRecommendationBalance).toBe(50);
    expect(processedDocs["2000000123456789"]).toMatchObject({
      uid: "user-1",
      productId: "com.visionclother.credits.recs50",
      creditType: "recommendation",
      amount: 50,
      revoked: false,
    });
  });

  it("adds on top of an existing balance without touching monthly counters", async () => {
    usageDoc = { periodKey: "2026-07", recommendationCount: 42, tryOnCount: 3, purchasedRecommendationBalance: 5 };
    mockedVerify.mockResolvedValueOnce(verifiedTransaction());
    const res = await request(appWith("user-1", false)).post("/iap/verify").send({ jws: "signed" });
    expect(res.status).toBe(200);
    expect(res.body.newBalance).toBe(55);
    expect(usageDoc?.purchasedRecommendationBalance).toBe(55);
    expect(usageDoc?.recommendationCount).toBe(42);
    expect(usageDoc?.tryOnCount).toBe(3);
    expect(usageDoc?.periodKey).toBe("2026-07");
  });

  it("returns alreadyProcessed for a replayed transactionId and grants nothing", async () => {
    processedDocs["2000000123456789"] = { uid: "user-1", amount: 50 };
    usageDoc = { purchasedRecommendationBalance: 50 };
    mockedVerify.mockResolvedValueOnce(verifiedTransaction());
    const res = await request(appWith("user-1", false)).post("/iap/verify").send({ jws: "signed" });
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ granted: true, alreadyProcessed: true });
    expect(usageDoc?.purchasedRecommendationBalance).toBe(50);
  });

  it("rejects an unknown product with 400 and writes nothing", async () => {
    mockedVerify.mockResolvedValueOnce(verifiedTransaction({ productId: "com.visionclother.credits.bogus" }));
    const res = await request(appWith("user-1", false)).post("/iap/verify").send({ jws: "signed" });
    expect(res.status).toBe(400);
    expect(res.body.error).toBe("unknown_product");
    expect(usageDoc).toBeUndefined();
    expect(processedDocs).toEqual({});
  });

  it("records a revoked transaction without granting", async () => {
    mockedVerify.mockResolvedValueOnce(verifiedTransaction({ revoked: true }));
    const res = await request(appWith("user-1", false)).post("/iap/verify").send({ jws: "signed" });
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ granted: false, reason: "revoked" });
    expect(usageDoc).toBeUndefined();
    expect(processedDocs["2000000123456789"]).toMatchObject({ revoked: true, amount: 0 });
  });

  it("maps a verifier invalid_transaction rejection to 400", async () => {
    mockedVerify.mockRejectedValueOnce(new IapVerifyError("invalid_transaction", "bad signature"));
    const res = await request(appWith("user-1", false)).post("/iap/verify").send({ jws: "forged" });
    expect(res.status).toBe(400);
    expect(res.body.error).toBe("invalid_transaction");
  });

  it("maps a verifier environment_not_supported rejection to 403", async () => {
    mockedVerify.mockRejectedValueOnce(new IapVerifyError("environment_not_supported", "production not configured"));
    const res = await request(appWith("user-1", false)).post("/iap/verify").send({ jws: "prod" });
    expect(res.status).toBe(403);
    expect(res.body.error).toBe("environment_not_supported");
  });

  it("fails closed (503) on a Firestore error so the client retries later", async () => {
    mockedVerify.mockResolvedValueOnce(verifiedTransaction());
    runTransaction.mockRejectedValueOnce(new Error("firestore down"));
    const res = await request(appWith("user-1", false)).post("/iap/verify").send({ jws: "signed" });
    expect(res.status).toBe(503);
    expect(res.body.error).toBe("temporarily_unavailable");
  });
});
