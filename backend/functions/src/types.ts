import type { Request } from "express";

/**
 * Populated by verifyAuth after a valid Firebase ID token is checked.
 * Every route handler runs after verifyAuth, so this is always set by
 * the time a route body executes.
 */
export interface AuthedRequest extends Request {
  uid?: string;
}
