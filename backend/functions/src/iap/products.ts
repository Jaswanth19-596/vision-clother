/**
 * The server-authoritative consumable-credit catalog. A verified purchase
 * grants credits from THIS table only — the client never sends an amount,
 * so a tampered client can at worst buy a real product and receive exactly
 * what that product grants.
 *
 * Kept in sync by hand with the client's display-only mirror
 * (`Vision_clother/Domain/CreditPack.swift`) and the App Store Connect /
 * `.storekit` product definitions — same posture as `TIER_LIMITS`
 * (middleware/governance.ts) vs `Domain/EntitlementLimits.swift`.
 */

export type CreditType = "recommendation" | "tryOn";

export interface ProductGrant {
  creditType: CreditType;
  amount: number;
}

export const PRODUCT_GRANTS: Record<string, ProductGrant> = {
  "com.visionclother.credits.recs50": { creditType: "recommendation", amount: 50 },
  "com.visionclother.credits.recs200": { creditType: "recommendation", amount: 200 },
  "com.visionclother.credits.tryon10": { creditType: "tryOn", amount: 10 },
  "com.visionclother.credits.tryon40": { creditType: "tryOn", amount: 40 },
};

/**
 * The lifetime purchased-balance field each credit type lives under on
 * `users/{uid}/meta/usage`. Lifetime fields: never reset by governance.ts's
 * monthly `periodKey` rollover, written only by `routes/iapVerify.ts`
 * (grant) and governance.ts's drawdown path (spend), always via field-scoped
 * `merge: true` sets so the two writers stay commutative.
 */
export const BALANCE_FIELD: Record<CreditType, "purchasedRecommendationBalance" | "purchasedTryOnBalance"> = {
  recommendation: "purchasedRecommendationBalance",
  tryOn: "purchasedTryOnBalance",
};
