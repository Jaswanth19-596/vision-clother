import { describe, expect, it, vi, beforeEach } from "vitest";
import express from "express";
import request from "supertest";

vi.mock("../src/secrets", () => ({
  openRouterApiKey: { value: () => "test-openrouter-key" },
  pexelsApiKey: { value: () => "test-pexels-key" },
}));

// No config/openrouterModels doc — modelAllowlist.ts falls back to its
// hardcoded DEFAULT_ALLOWED_MODELS, which is what these tests exercise.
vi.mock("firebase-admin/firestore", () => ({
  getFirestore: () => ({
    collection: () => ({
      doc: () => ({
        get: async () => ({ exists: false, data: () => undefined }),
      }),
    }),
  }),
}));

import { openrouterChatRouter } from "../src/routes/openrouterChat";
import { openrouterImagesRouter } from "../src/routes/openrouterImages";
import { pexelsSearchRouter } from "../src/routes/pexelsSearch";

const fetchMock = vi.fn();
vi.stubGlobal("fetch", fetchMock);

function jsonResponse(status: number, body: unknown) {
  return {
    status,
    headers: new Headers({ "Content-Type": "application/json" }),
    text: async () => JSON.stringify(body),
  } as Response;
}

beforeEach(() => {
  fetchMock.mockReset();
});

describe("openrouterChatRouter", () => {
  const app = express();
  app.use(express.json());
  app.use("/openrouter/chat", openrouterChatRouter);

  it("forwards a valid body to OpenRouter with the server-side key", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse(200, { choices: [{ message: { content: "{}" } }] }));

    const res = await request(app)
      .post("/openrouter/chat")
      .send({ model: "google/gemini-3.1-flash-lite", messages: [{ role: "user", content: "hi" }] });

    expect(res.status).toBe(200);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, init] = fetchMock.mock.calls[0];
    expect(url).toBe("https://openrouter.ai/api/v1/chat/completions");
    expect(init.headers.Authorization).toBe("Bearer test-openrouter-key");
    expect(JSON.parse(init.body).model).toBe("google/gemini-3.1-flash-lite");
  });

  it("rejects a body missing required fields without calling upstream", async () => {
    const res = await request(app).post("/openrouter/chat").send({ model: "x" });
    expect(res.status).toBe(400);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("passes through an upstream error status", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse(429, { error: { message: "rate limited" } }));
    const res = await request(app)
      .post("/openrouter/chat")
      .send({ model: "google/gemini-3.1-flash-lite", messages: [{ role: "user", content: "hi" }] });
    expect(res.status).toBe(429);
  });

  it("rejects a model not on the allowlist without calling upstream", async () => {
    const res = await request(app)
      .post("/openrouter/chat")
      .send({ model: "anthropic/claude-opus-4", messages: [{ role: "user", content: "hi" }] });
    expect(res.status).toBe(403);
    expect(res.body.error).toBe("model_not_allowed");
    expect(fetchMock).not.toHaveBeenCalled();
  });
});

describe("openrouterImagesRouter", () => {
  const app = express();
  app.use(express.json({ limit: "15mb" }));
  app.use("/openrouter/images", openrouterImagesRouter);

  it("forwards a valid body to OpenRouter's images endpoint", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse(200, { data: [{ url: "https://example.com/x.png" }] }));

    const res = await request(app)
      .post("/openrouter/images")
      .send({ model: "bytedance-seed/seedream-4.5", prompt: "outfit render" });

    expect(res.status).toBe(200);
    const [url] = fetchMock.mock.calls[0];
    expect(url).toBe("https://openrouter.ai/api/v1/images");
  });

  it("rejects a model not on the allowlist without calling upstream", async () => {
    const res = await request(app)
      .post("/openrouter/images")
      .send({ model: "stability-ai/sdxl", prompt: "outfit render" });
    expect(res.status).toBe(403);
    expect(res.body.error).toBe("model_not_allowed");
    expect(fetchMock).not.toHaveBeenCalled();
  });
});

describe("pexelsSearchRouter", () => {
  const app = express();
  app.use("/pexels/search", pexelsSearchRouter);

  it("forwards query params to Pexels with a raw (non-Bearer) key", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse(200, { photos: [] }));

    const res = await request(app).get("/pexels/search").query({ query: "menswear", per_page: "10" });

    expect(res.status).toBe(200);
    const [url, init] = fetchMock.mock.calls[0];
    expect(url.toString()).toContain("query=menswear");
    expect(init.headers.Authorization).toBe("test-pexels-key");
  });

  it("rejects a request with no query param", async () => {
    const res = await request(app).get("/pexels/search");
    expect(res.status).toBe(400);
    expect(fetchMock).not.toHaveBeenCalled();
  });
});
