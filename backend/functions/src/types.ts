import type { Request } from "express";
import type { OperationType, PricingConfig } from "./pricing.config";
import type { ResponseCacheLookup } from "./middleware/responseCache";

/**
 * Populated by verifyAuth after a valid Firebase ID token is checked.
 * Every route handler runs after verifyAuth, so this is always set by
 * the time a route body executes.
 */
export interface AuthedRequest extends Request {
  uid?: string;
  isAnonymous?: boolean;
  /**
   * Minted by app.ts's request-logging middleware (or read from the
   * client's `X-Request-Id` header when present) — the join key with the
   * iOS-side `AppLog` line for the same call, see `Services/ProxyAuthHeaders.swift`.
   */
  requestId?: string;
  /**
   * Set by `middleware/creditGate.ts`'s `creditGate` the moment it actually
   * debits credits (its ALLOWED outcome) — absent when creditGate rejected
   * the request (429) or never ran at all. Split into the two wallet buckets
   * actually debited (subscription first, purchased for the remainder) so
   * `refundCredit` can restore credits to the exact bucket(s) they came from
   * instead of guessing. `middleware/idempotency.ts` reads this after the
   * downstream handler finishes to decide whether a failure needs
   * `creditGate.ts`'s `refundCredit` to undo a real debit.
   */
  quotaDebit?: { operation: OperationType; subscriptionDebited: number; purchasedDebited: number };
  /**
   * Raw JSON bytes captured by app.ts's `express.json` `verify` callback,
   * before parsing — lets `middleware/responseCache.ts` hash the wire bytes
   * directly instead of re-serializing the already-parsed `req.body`.
   * Undefined when no JSON body was parsed (e.g. a bodyless GET).
   */
  rawBody?: Buffer;
  /**
   * Kicked off by `middleware/prefetchGates.ts`'s `prefetchPreLLMReads`
   * before `idempotencyGate` runs, so these independent, side-effect-free
   * Firestore reads happen concurrently with `idempotencyGate`'s lock-claim
   * transaction instead of stacking sequentially after it. Each downstream
   * consumer (`responseCache.ts`, `creditGate.ts`, the openrouter routers)
   * prefers its own prefetch field when present and falls back to fetching
   * fresh when absent (any route that doesn't mount `prefetchPreLLMReads`).
   * None of these three promises can reject — see `prefetchGates.ts`.
   */
  responseCachePrefetch?: Promise<ResponseCacheLookup>;
  pricingConfigPrefetch?: Promise<PricingConfig>;
  modelAllowlistPrefetch?: Promise<readonly string[]>;
}
