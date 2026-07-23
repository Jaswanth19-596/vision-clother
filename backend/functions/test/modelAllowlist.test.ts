import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";
import { isModelAllowed } from "../src/modelAllowlist";

let doc: Record<string, unknown> | undefined;
let getCallCount: number;
let failNextGet: boolean;

const docRef = {
  get: async () => {
    if (failNextGet) {
      failNextGet = false;
      throw new Error("boom");
    }
    getCallCount += 1;
    return { exists: doc !== undefined, data: () => doc };
  },
};

vi.mock("firebase-admin/firestore", () => ({
  getFirestore: () => ({
    collection: () => ({
      doc: () => docRef,
    }),
  }),
}));

const DEFAULT_ALLOWED_MODELS = [
  "google/gemini-3.1-flash-lite",
  "openai/gpt-5-mini",
  "minimax/minimax-m3",
  "google/gemini-3.1-flash-lite-image",
  "qwen/qwen3-vl-30b-a3b-instruct",
  "bytedance-seed/seedream-4.5",
  "google/gemini-2.5-flash-image",
];

/**
 * modelAllowlist.ts's cache is a module-scope singleton, so each test that
 * exercises it needs a fresh module instance — vi.resetModules() clears the
 * import cache, and a dynamic re-import gives this test its own untouched
 * `cache = null` starting state.
 */
async function freshModule() {
  vi.resetModules();
  return import("../src/modelAllowlist");
}

beforeEach(() => {
  doc = undefined;
  getCallCount = 0;
  failNextGet = false;
});

afterEach(() => {
  vi.useRealTimers();
});

describe("isModelAllowed", () => {
  it("matches an exact model id", () => {
    expect(isModelAllowed("google/gemini-3.1-flash-lite", DEFAULT_ALLOWED_MODELS)).toBe(true);
  });

  it("rejects a model not in the list, including prefix-only matches", () => {
    expect(isModelAllowed("google/gemini-3-pro-ultra-max", DEFAULT_ALLOWED_MODELS)).toBe(false);
    expect(isModelAllowed("anthropic/claude-opus-4", DEFAULT_ALLOWED_MODELS)).toBe(false);
  });
});

describe("getAllowedModels / assertModelAllowed", () => {
  it("falls back to the hardcoded defaults when the doc doesn't exist", async () => {
    const { getAllowedModels } = await freshModule();
    const models = await getAllowedModels("test-request");
    expect(models).toEqual(DEFAULT_ALLOWED_MODELS);
  });

  it("falls back to the hardcoded defaults when the doc is malformed", async () => {
    doc = { allowedModels: "not-an-array" };
    const { getAllowedModels } = await freshModule();
    const models = await getAllowedModels("test-request");
    expect(models).toEqual(DEFAULT_ALLOWED_MODELS);
  });

  it("uses the Firestore doc's list when present and valid", async () => {
    doc = { allowedModels: ["only/this-one"] };
    const { getAllowedModels, assertModelAllowed } = await freshModule();
    const models = await getAllowedModels("test-request");
    expect(models).toEqual(["only/this-one"]);
    expect(await assertModelAllowed("only/this-one", "test-request")).toBe(true);
    expect(await assertModelAllowed("google/gemini-3.1-flash-lite", "test-request")).toBe(false);
  });

  it("falls back to defaults on a Firestore read failure with no prior cache", async () => {
    failNextGet = true;
    const { getAllowedModels } = await freshModule();
    const models = await getAllowedModels("test-request");
    expect(models).toEqual(DEFAULT_ALLOWED_MODELS);
  });

  it("serves a stale cached value on a Firestore read failure rather than reverting to defaults", async () => {
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date("2026-07-21T12:00:00.000Z"));

    doc = { allowedModels: ["custom/model-a"] };
    const { getAllowedModels } = await freshModule();
    const first = await getAllowedModels("test-request");
    expect(first).toEqual(["custom/model-a"]);

    vi.setSystemTime(new Date("2026-07-21T12:05:01.000Z")); // +5m1s, past the 5m TTL
    failNextGet = true;

    const second = await getAllowedModels("test-request");
    expect(second).toEqual(["custom/model-a"]); // stale cache, not DEFAULT_ALLOWED_MODELS
  });

  it("re-reads once the cache TTL expires (no failure)", async () => {
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date("2026-07-21T12:00:00.000Z"));

    doc = { allowedModels: ["only/this-one"] };
    const { getAllowedModels } = await freshModule();
    await getAllowedModels("test-request");
    expect(getCallCount).toBe(1);

    vi.setSystemTime(new Date("2026-07-21T12:05:01.000Z")); // +5m1s, past the 5m TTL
    doc = { allowedModels: ["updated/model"] };
    const models = await getAllowedModels("test-request");
    expect(getCallCount).toBe(2);
    expect(models).toEqual(["updated/model"]);
  });

  it("caches across calls, avoiding a second Firestore read within the TTL", async () => {
    doc = { allowedModels: ["only/this-one"] };
    const { getAllowedModels } = await freshModule();
    await getAllowedModels("test-request");
    expect(getCallCount).toBe(1);

    await getAllowedModels("test-request");
    expect(getCallCount).toBe(1); // fast path, no second read
  });
});
