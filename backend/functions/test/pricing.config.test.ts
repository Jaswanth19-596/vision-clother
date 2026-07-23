import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";

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

const DEFAULT_OPERATION_COSTS = { UPLOAD: 0, IMAGE_GEN: 5, RECOMMENDATION: 1 };

/**
 * pricing.config.ts's cache is a module-scope singleton, so each test that
 * exercises it needs a fresh module instance — vi.resetModules() clears the
 * import cache, and a dynamic re-import gives this test its own untouched
 * `cache = null` starting state.
 */
async function freshModule() {
  vi.resetModules();
  return import("../src/pricing.config");
}

beforeEach(() => {
  doc = undefined;
  getCallCount = 0;
  failNextGet = false;
});

afterEach(() => {
  vi.useRealTimers();
});

describe("getPricingConfig", () => {
  it("falls back to the hardcoded defaults when the doc doesn't exist", async () => {
    const { getPricingConfig, DEFAULT_TIER_CONFIGS } = await freshModule();
    const config = await getPricingConfig("test-request");
    expect(config.operationCosts).toEqual(DEFAULT_OPERATION_COSTS);
    expect(config.tierConfigs).toEqual(DEFAULT_TIER_CONFIGS);
  });

  it("falls back to the hardcoded defaults when the doc is malformed", async () => {
    doc = { operationCosts: { UPLOAD: 0 }, tierConfigs: {} }; // missing keys / empty tiers
    const { getPricingConfig } = await freshModule();
    const config = await getPricingConfig("test-request");
    expect(config.operationCosts).toEqual(DEFAULT_OPERATION_COSTS);
  });

  it("uses the Firestore doc's config when present and valid", async () => {
    doc = {
      operationCosts: { UPLOAD: 2, IMAGE_GEN: 10, RECOMMENDATION: 3 },
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
    const { getPricingConfig } = await freshModule();
    const config = await getPricingConfig("test-request");
    expect(config.operationCosts).toEqual({ UPLOAD: 2, IMAGE_GEN: 10, RECOMMENDATION: 3 });
    expect(config.tierConfigs.FREE.creditAllocation).toBe(100);
  });

  it("falls back to defaults on a Firestore read failure with no prior cache", async () => {
    failNextGet = true;
    const { getPricingConfig } = await freshModule();
    const config = await getPricingConfig("test-request");
    expect(config.operationCosts).toEqual(DEFAULT_OPERATION_COSTS);
  });

  it("serves a stale cached value on a Firestore read failure rather than reverting to defaults", async () => {
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date("2026-07-22T12:00:00.000Z"));

    doc = {
      operationCosts: { UPLOAD: 9, IMAGE_GEN: 9, RECOMMENDATION: 9 },
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
    const { getPricingConfig } = await freshModule();
    const first = await getPricingConfig("test-request");
    expect(first.operationCosts.UPLOAD).toBe(9);

    vi.setSystemTime(new Date("2026-07-22T12:01:01.000Z")); // +1m1s, past the 1m TTL
    failNextGet = true;

    const second = await getPricingConfig("test-request");
    expect(second.operationCosts.UPLOAD).toBe(9); // stale cache, not defaults
  });

  it("re-reads once the cache TTL expires (no failure)", async () => {
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date("2026-07-22T12:00:00.000Z"));

    doc = {
      operationCosts: { UPLOAD: 1, IMAGE_GEN: 1, RECOMMENDATION: 1 },
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
    const { getPricingConfig } = await freshModule();
    await getPricingConfig("test-request");
    expect(getCallCount).toBe(1);

    vi.setSystemTime(new Date("2026-07-22T12:01:01.000Z")); // +1m1s, past the 1m TTL
    doc = { ...doc, operationCosts: { UPLOAD: 2, IMAGE_GEN: 2, RECOMMENDATION: 2 } };
    const config = await getPricingConfig("test-request");
    expect(getCallCount).toBe(2);
    expect(config.operationCosts.UPLOAD).toBe(2);
  });

  it("caches across calls, avoiding a second Firestore read within the TTL", async () => {
    doc = {
      operationCosts: { UPLOAD: 1, IMAGE_GEN: 1, RECOMMENDATION: 1 },
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
    const { getPricingConfig } = await freshModule();
    await getPricingConfig("test-request");
    expect(getCallCount).toBe(1);

    await getPricingConfig("test-request");
    expect(getCallCount).toBe(1); // fast path, no second read
  });

  /**
   * The crux proof required by the task spec: adding a brand-new tier key
   * that exists ONLY in the mocked Firestore doc (never touching any TS
   * source) is resolvable with no code change.
   */
  it("resolves a dynamically-added tier (e.g. ULTRA_PRO) defined only in the Firestore doc", async () => {
    doc = {
      operationCosts: DEFAULT_OPERATION_COSTS,
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
          itemCap: { core: 200, accessory: 200 },
        },
      },
    };
    const { getPricingConfig, getTierConfig } = await freshModule();
    const config = await getPricingConfig("test-request");
    const ultraPro = getTierConfig("ULTRA_PRO", config);
    expect(ultraPro?.creditAllocation).toBe(5000);
    expect(ultraPro?.autoReset).toBe(true);
  });
});

describe("getOperationCost / getTierConfig", () => {
  it("reads costs and tiers from a given config object", async () => {
    const { getOperationCost, getTierConfig, DEFAULT_TIER_CONFIGS } = await freshModule();
    const config = { operationCosts: DEFAULT_OPERATION_COSTS, tierConfigs: DEFAULT_TIER_CONFIGS };
    expect(getOperationCost("RECOMMENDATION", config)).toBe(1);
    expect(getTierConfig("GUEST", config)?.hardCaps?.IMAGE_GEN).toBe(0);
    expect(getTierConfig("NOT_A_TIER", config)).toBeUndefined();
  });
});
