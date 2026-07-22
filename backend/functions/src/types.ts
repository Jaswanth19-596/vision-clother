import type { Request } from "express";
import type { QuotaFeature } from "./middleware/governance";

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
   * Set by `middleware/governance.ts`'s `governanceGate` the moment it
   * actually debits usage (fast-path count increment, or the slow-path
   * "ok"/"ok_purchased" transaction outcomes) — absent when governanceGate
   * rejected the request (429/403) or never ran at all.
   * `middleware/idempotency.ts` reads this after the downstream handler
   * finishes to decide whether a failure needs `governance.ts`'s
   * `refundQuota` to undo a real debit.
   */
  quotaDebit?: { feature: QuotaFeature; kind: "count" | "purchased" };
}
