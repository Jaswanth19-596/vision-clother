import { describe, expect, it, vi, beforeEach } from "vitest";
import express from "express";
import request from "supertest";

const verifyIdToken = vi.fn();

vi.mock("firebase-admin/auth", () => ({
  getAuth: () => ({ verifyIdToken }),
}));

import { verifyAuth } from "../src/middleware/verifyAuth";

function appWith(...middleware: express.RequestHandler[]) {
  const app = express();
  app.use(...middleware);
  app.get("/protected", (_req, res) => res.status(200).json({ ok: true }));
  return app;
}

beforeEach(() => {
  verifyIdToken.mockReset();
});

describe("verifyAuth", () => {
  const app = appWith(verifyAuth);

  it("rejects a request with no Authorization header", async () => {
    const res = await request(app).get("/protected");
    expect(res.status).toBe(401);
    expect(res.body.error).toBe("missing_id_token");
  });

  it("rejects a request with an invalid ID token", async () => {
    verifyIdToken.mockRejectedValueOnce(new Error("bad token"));
    const res = await request(app).get("/protected").set("Authorization", "Bearer bogus");
    expect(res.status).toBe(401);
    expect(res.body.error).toBe("invalid_id_token");
  });

  it("allows a request with a valid ID token", async () => {
    verifyIdToken.mockResolvedValueOnce({ uid: "user-1" });
    const res = await request(app).get("/protected").set("Authorization", "Bearer good");
    expect(res.status).toBe(200);
  });
});
