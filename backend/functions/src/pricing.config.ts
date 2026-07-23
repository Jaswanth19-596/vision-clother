import { getFirestore } from "firebase-admin/firestore";
import { logEvent } from "./logger";

/**
 * Single canonical source for operation costs and tier definitions — the
 * "dynamic credit & tier management engine" config. Replaces the old
 * `entitlementLimits.ts` (fixed guest/free/premium counters). Firestore-backed
 * (`config/pricing`) so ops can retune a cost or add a brand-new tier (e.g. a
 * test `ULTRA_PRO`) without a backend redeploy or any code change — mirrors
 * `modelAllowlist.ts`'s exact pattern: hardcoded fallback, warm-instance TTL
 * cache, stale-cache-preferred-on-failure. Consumed by
 * `middleware/creditGate.ts` (enforcement) and `routes/entitlementLimits.ts`
 * (the resolved-numbers readout the iOS client fetches instead of
 * hardcoding its own copy).
 *
 * `backend/firestore.rules`' `itemCap()` is the one place these numbers still
 * can't be read from here — Firestore Security Rules have no module system
 * and cannot reach an arbitrary ops-editable Firestore doc for this purpose
 * either. A tier's `itemCap` is therefore only enforced at the rules layer
 * for tiers hand-mirrored into `itemCap()` (today: GUEST/FREE/PRO). A tier
 * added *only* via the `config/pricing` doc gets full credit-engine
 * enforcement immediately, but its wardrobe item-cap enforcement falls back
 * to FREE's numbers until `itemCap()` is hand-updated and redeployed — see
 * that function's comment in `firestore.rules`.
 */

export type OperationType = "UPLOAD" | "IMAGE_GEN" | "RECOMMENDATION";

export interface TierConfig {
  id: string;
  displayName: string;
  monthlyPriceCents: number;
  /** One-time welcome-pack amount (non-recurring tiers) or monthly refill amount (recurring tiers). */
  creditAllocation: number;
  /** Recurring monthly refill (PRO) vs one-time grant that never auto-refills (FREE/GUEST). */
  autoReset: boolean;
  /** Optional hard ceiling per operation type, independent of credit balance — e.g. GUEST's IMAGE_GEN: 0. */
  hardCaps?: Partial<Record<OperationType, number>>;
  itemCap: { core: number; accessory: number };
}

export interface PricingConfig {
  operationCosts: Record<OperationType, number>;
  tierConfigs: Record<string, TierConfig>;
}

/**
 * UPLOAD is defined here (and enforceable by `creditGate.ts`) but has no
 * mounted route yet — wardrobe photo uploads still go straight to Cloud
 * Storage, unchanged. Cost of 0 until a real upload gate is wired up.
 */
export const DEFAULT_OPERATION_COSTS: Record<OperationType, number> = {
  UPLOAD: 0,
  IMAGE_GEN: 5,
  RECOMMENDATION: 1,
};

/**
 * Placeholder numbers (pricing isn't finalized) — tune freely via
 * `config/pricing`, nothing else depends on the exact values. GUEST's
 * `IMAGE_GEN: 0` hard cap preserves the old guest-blocked-from-tryOn
 * behavior via the general cap mechanism instead of a special case.
 */
export const DEFAULT_TIER_CONFIGS: Record<string, TierConfig> = {
  GUEST: {
    id: "GUEST",
    displayName: "Guest",
    monthlyPriceCents: 0,
    creditAllocation: 20,
    autoReset: false,
    hardCaps: { IMAGE_GEN: 0 },
    itemCap: { core: 5, accessory: 2 },
  },
  FREE: {
    id: "FREE",
    displayName: "Free",
    monthlyPriceCents: 0,
    creditAllocation: 100,
    autoReset: false,
    itemCap: { core: 10, accessory: 4 },
  },
  PRO: {
    id: "PRO",
    displayName: "Pro",
    monthlyPriceCents: 999,
    creditAllocation: 500,
    autoReset: true,
    itemCap: { core: 50, accessory: 25 },
  },
};

/** `core` = top/bottom/footwear (`Slot.isRequired`); `accessory` = everything else. Mirrors `Models/WardrobeItem.swift`'s `Slot` raw values. */
export const CORE_SLOTS = ["top", "bottom", "footwear"] as const;
export const ACCESSORY_SLOTS = ["outerwear", "headwear", "accessory", "bag"] as const;

export function itemCapForSlot(slot: string, itemCap: { core: number; accessory: number }): number {
  return (CORE_SLOTS as readonly string[]).includes(slot) ? itemCap.core : itemCap.accessory;
}

/**
 * This config changes at ops pace, not per-request — same TTL rationale as
 * `modelAllowlist.ts`, but deliberately shorter (1 minute vs. `modelAllowlist.ts`'s
 * 5): an ops price/cap change needs to reach every warm instance quickly, while
 * the model allowlist changes far less often and can tolerate more staleness.
 */
const CACHE_TTL_MS = 60_000;

interface PricingCache {
  cachedAt: number;
  config: PricingConfig;
}

/** Module-scope — survives across requests on the same warm instance, never shared cross-instance. */
let cache: PricingCache | null = null;

function isFresh(entry: PricingCache): boolean {
  return Date.now() - entry.cachedAt < CACHE_TTL_MS;
}

function isValidOperationCosts(value: unknown): value is Record<OperationType, number> {
  if (typeof value !== "object" || value === null) return false;
  const v = value as Record<string, unknown>;
  return (["UPLOAD", "IMAGE_GEN", "RECOMMENDATION"] as const).every(
    (key) => typeof v[key] === "number" && Number.isFinite(v[key] as number) && (v[key] as number) >= 0
  );
}

function isValidTierConfig(value: unknown): value is TierConfig {
  if (typeof value !== "object" || value === null) return false;
  const v = value as Record<string, unknown>;
  const itemCap = v.itemCap as Record<string, unknown> | undefined;
  return (
    typeof v.id === "string" &&
    typeof v.displayName === "string" &&
    typeof v.monthlyPriceCents === "number" &&
    typeof v.creditAllocation === "number" &&
    typeof v.autoReset === "boolean" &&
    typeof itemCap === "object" &&
    itemCap !== null &&
    typeof itemCap.core === "number" &&
    typeof itemCap.accessory === "number"
  );
}

function isValidTierConfigs(value: unknown): value is Record<string, TierConfig> {
  if (typeof value !== "object" || value === null) return false;
  const entries = Object.entries(value as Record<string, unknown>);
  return entries.length > 0 && entries.every(([, v]) => isValidTierConfig(v));
}

async function fetchPricingConfig(requestId: string | undefined): Promise<PricingConfig> {
  try {
    const snapshot = await getFirestore().collection("config").doc("pricing").get();
    const data = snapshot.data();
    const operationCosts = data?.operationCosts;
    const tierConfigs = data?.tierConfigs;
    if (!isValidOperationCosts(operationCosts) || !isValidTierConfigs(tierConfigs)) {
      logEvent("warn", "pricingConfig.usingDefaults", { requestId, reason: "doc_missing_or_malformed" });
      return { operationCosts: DEFAULT_OPERATION_COSTS, tierConfigs: DEFAULT_TIER_CONFIGS };
    }
    return { operationCosts, tierConfigs };
  } catch (error) {
    logEvent("warn", "pricingConfig.firestoreUnreachable", { requestId, error: String(error) });
    // Prefer a stale-but-previously-valid config over the hardcoded defaults,
    // same rationale as modelAllowlist.ts — only fall through to the
    // hardcoded defaults when there's no prior cache at all (cold start
    // during an outage). Never fails open.
    if (cache) return cache.config;
    return { operationCosts: DEFAULT_OPERATION_COSTS, tierConfigs: DEFAULT_TIER_CONFIGS };
  }
}

/** Returns the current pricing config, using the warm-instance cache when fresh. */
export async function getPricingConfig(requestId: string | undefined): Promise<PricingConfig> {
  if (cache && isFresh(cache)) return cache.config;
  const config = await fetchPricingConfig(requestId);
  cache = { cachedAt: Date.now(), config };
  return config;
}

export function getOperationCost(operation: OperationType, config: PricingConfig): number {
  return config.operationCosts[operation];
}

export function getTierConfig(tierId: string, config: PricingConfig): TierConfig | undefined {
  return config.tierConfigs[tierId];
}
