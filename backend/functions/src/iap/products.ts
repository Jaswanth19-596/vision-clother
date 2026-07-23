/**
 * The server-authoritative consumable-credit catalog. A verified purchase
 * grants credits from THIS table only — the client never sends an amount,
 * so a tampered client can at worst buy a real product and receive exactly
 * what that product grants.
 *
 * Credits are fully fungible across operation types: a purchased top-up adds
 * to `purchased_credits_remaining`, spendable on any operation
 * (UPLOAD/IMAGE_GEN/RECOMMENDATION) — collapsed from the previous per-feature-
 * scoped balances as part of the single-credit-currency rewrite (see
 * docs/timeline.md). Kept in a separate, permanent bucket from
 * `subscription_credits_remaining` (`middleware/creditGate.ts`) so a paid
 * top-up is never wiped by a subscription's monthly billing-cycle reset —
 * required for Apple IAP compliance (a purchased consumable must remain the
 * user's property until spent).
 *
 * Kept in sync by hand with the client's display-only mirror
 * (`Vision_clother/Domain/CreditPack.swift`) and the App Store Connect /
 * `.storekit` product definitions.
 */

export interface ProductGrant {
  amount: number;
}

export const PRODUCT_GRANTS: Record<string, ProductGrant> = {
  "com.visionclother.credits.recs50": { amount: 50 },
  "com.visionclother.credits.recs200": { amount: 200 },
  "com.visionclother.credits.tryon10": { amount: 10 },
  "com.visionclother.credits.tryon40": { amount: 40 },
};
