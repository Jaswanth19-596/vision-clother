import type { Request } from "express";
import type { OperationType } from "./pricing.config";

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
}
