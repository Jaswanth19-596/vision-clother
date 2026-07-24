import type { NextFunction, Response } from "express";
import type { AuthedRequest } from "../types";
import { lookupResponseCache } from "./responseCache";
import { getPricingConfig } from "../pricing.config";
import { getAllowedModels } from "../modelAllowlist";

/**
 * Kicks off `responseCache`'s doc lookup, `creditGate`'s pricing-config
 * read, and the model-allowlist read all at once, stashing each as an
 * in-flight promise on `req` — see `types.ts`'s `*Prefetch` fields. Must be
 * mounted BEFORE `idempotencyGate` in `app.ts`'s `/openrouter/recommend`
 * chain (the only current mount point).
 *
 * Why this is safe to run ahead of (i.e. without waiting on)
 * `idempotencyGate`'s lock-claim transaction: all three of these reads are
 * pure — none of them write anything, and none of them depend on whether
 * this request turns out to be a fresh attempt, a `COMPLETED` replay, or an
 * in-flight `conflict`. If `idempotencyGate` ends up short-circuiting, these
 * three settled promises are simply never awaited/consumed downstream — a
 * wasted read, not a wasted write, and therefore not a correctness issue.
 * `idempotencyGate` itself, and the debit half of `creditGate`'s
 * transaction, can NOT be front-loaded the same way: those two write, and
 * `creditGate`'s debit must only ever happen once `idempotencyGate` has
 * already confirmed this call isn't a duplicate/racing one — see
 * `idempotency.ts`'s and `creditGate.ts`'s doc comments.
 *
 * `getPricingConfig`/`getAllowedModels` never reject (both internally catch
 * every Firestore error and fall back to a stale cache or hardcoded
 * defaults), and `lookupResponseCache` is written the same way, so none of
 * these three promises can surface as an unhandled rejection in the window
 * before a downstream middleware actually awaits them.
 */
export function prefetchPreLLMReads() {
  return (req: AuthedRequest, _res: Response, next: NextFunction): void => {
    const uid = req.uid;
    if (uid) {
      req.responseCachePrefetch = lookupResponseCache(req, uid);
      req.pricingConfigPrefetch = getPricingConfig(req.requestId);
      req.modelAllowlistPrefetch = getAllowedModels(req.requestId);
    }
    next();
  };
}
