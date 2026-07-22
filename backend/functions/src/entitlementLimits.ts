/**
 * Single canonical source for every tier's numeric limits — imported by
 * `middleware/governance.ts` (enforcement) and `routes/entitlementLimits.ts`
 * (the resolved-numbers readout the iOS client fetches instead of
 * hardcoding its own copy, see `Vision_clother/Services/EntitlementLimitsService.swift`).
 *
 * `backend/firestore.rules`' `itemCap()` is the one place these numbers
 * still can't be imported from here — Firestore Security Rules have no
 * module system — so its core/accessory literals must stay hand-kept in
 * sync with `ITEM_CAP_LIMITS` below. Everywhere else (Cloud Functions, the
 * iOS client) now derives from this file alone.
 */

export type Tier = "guest" | "free" | "premium";

export interface TierLimits {
  recommendation: number;
  tryOn: number;
}

/**
 * Premium numbers are placeholders (pricing isn't designed yet) — generous
 * headroom for the manually-flagged testing case (see docs/timeline.md),
 * not a final billing tier. Tune freely; nothing else depends on the exact
 * values.
 */
export const TIER_LIMITS: Partial<Record<Tier, TierLimits>> = {
  guest: { recommendation: 20, tryOn: 0 },
  free: { recommendation: 100, tryOn: 10 },
  premium: { recommendation: 500, tryOn: 100 },
};

/** `core` = top/bottom/footwear (`Slot.isRequired`); `accessory` = everything else. */
export interface ItemCapLimits {
  core: number;
  accessory: number;
}

export const ITEM_CAP_LIMITS: Record<Tier, ItemCapLimits> = {
  guest: { core: 5, accessory: 2 },
  free: { core: 10, accessory: 4 },
  premium: { core: 50, accessory: 25 },
};

/** Mirrors `Models/WardrobeItem.swift`'s `Slot` raw values. */
export const CORE_SLOTS = ["top", "bottom", "footwear"] as const;
export const ACCESSORY_SLOTS = ["outerwear", "headwear", "accessory", "bag"] as const;

export function itemCapForSlot(slot: string, limits: ItemCapLimits): number {
  return (CORE_SLOTS as readonly string[]).includes(slot) ? limits.core : limits.accessory;
}
