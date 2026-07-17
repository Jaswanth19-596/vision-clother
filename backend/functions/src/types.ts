import type { Request } from "express";

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
}
