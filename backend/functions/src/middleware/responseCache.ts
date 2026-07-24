import type { NextFunction, Response } from "express";
import { createHash, webcrypto } from "crypto";
import { getFirestore } from "firebase-admin/firestore";
import type { AuthedRequest } from "../types";
import { logEvent } from "../logger";

/** Short enough that a genuinely changed wardrobe/scenario is never stale for long. */
const TTL_MS = 10 * 60 * 1000;

interface CachedResponse {
  status: number;
  contentType: string;
  body: string;
  expiresAt: number;
}

export interface ResponseCacheLookup {
  ref: FirebaseFirestore.DocumentReference;
  cacheKey: string;
  /** null on a lookup failure — same fail-open posture as the old inline try/catch. */
  snapshot: FirebaseFirestore.DocumentSnapshot | null;
  error?: unknown;
}

/**
 * Computes the per-uid cache doc ref and performs the lookup `.get()`.
 * Extracted so `middleware/prefetchGates.ts` can kick this off concurrently
 * with `idempotencyGate`'s lock-claim transaction instead of waiting for it
 * to resolve first — see that file's doc comment. Never throws/rejects: a
 * Firestore error here is reported via `error`, matching this middleware's
 * existing fail-open behavior on the read side.
 *
 * Hashes the raw wire bytes (captured by app.ts's express.json `verify`
 * callback) rather than re-serializing the already-parsed req.body — and
 * does it with the async Web Crypto digest, which Node offloads to the
 * libuv threadpool, instead of the synchronous `createHash` API. Both
 * choices exist to keep this off the main event-loop thread: the
 * catalog-bearing `/openrouter/recommend` body can run tens to hundreds of
 * KB, and a sync JSON.stringify + sha256 over that would otherwise block
 * every other in-flight request on this instance for the duration. Falls
 * back to the old stringify+sync-hash path when rawBody is unset (e.g.
 * `/analytics/config`'s bodyless GET never triggers `verify`) — that body
 * is always `{}`, so the fallback's cost there is negligible.
 */
export async function lookupResponseCache(req: AuthedRequest, uid: string): Promise<ResponseCacheLookup> {
  const cacheKey = req.rawBody
    ? Buffer.from(await webcrypto.subtle.digest("SHA-256", req.rawBody)).toString("hex")
    : createHash("sha256").update(JSON.stringify(req.body ?? {})).digest("hex");
  const ref = getFirestore().collection("users").doc(uid).collection("responseCache").doc(cacheKey);

  try {
    const snapshot = await ref.get();
    return { ref, cacheKey, snapshot };
  } catch (error) {
    return { ref, cacheKey, snapshot: null, error };
  }
}

/**
 * Must run after verifyAuth (needs req.uid) and *before* creditGate for
 * `feature` in app.ts's mount chain — a cache hit responds directly and
 * returns without calling `next()`, which is what keeps a hit from ever
 * reaching creditGate or the upstream OpenRouter fetch (zero credits charged,
 * zero paid inference call) for a byte-identical repeat request (e.g. a
 * retry after a transient error, or the user re-triggering the same
 * scenario against an unchanged wardrobe).
 *
 * Keyed per-uid (`users/{uid}/responseCache/{hash}`) off a hash of the raw
 * request body — two users' requests can never collide (wardrobe catalogs
 * differ), and this keeps cached output cross-user-isolated by construction.
 *
 * Firestore errors here fail open on both the read and the write side — a
 * caching-layer hiccup should degrade to "no caching," never "no service."
 *
 * Prefers `req.responseCachePrefetch` (set by `middleware/prefetchGates.ts`
 * on `/openrouter/recommend`) over a fresh `lookupResponseCache` call so the
 * read fires concurrently with `idempotencyGate`'s transaction instead of
 * after it; other mount points (e.g. `/analytics/config`) never set that
 * field and transparently fall back to the lazy lookup, unchanged.
 */
export function responseCache(feature: string) {
  return async (req: AuthedRequest, res: Response, next: NextFunction): Promise<void> => {
    const uid = req.uid;
    if (!uid) {
      next();
      return;
    }

    const { ref, cacheKey, snapshot, error } = await (req.responseCachePrefetch ?? lookupResponseCache(req, uid));

    if (error) {
      logEvent("error", "responseCache.lookupFailOpen", { requestId: req.requestId, uid, feature, error: String(error) });
    } else if (snapshot) {
      const cached = snapshot.data() as CachedResponse | undefined;
      if (cached && cached.expiresAt > Date.now()) {
        logEvent("info", "responseCache.hit", { requestId: req.requestId, uid, feature, cacheKey });
        res.status(cached.status).setHeader("Content-Type", cached.contentType).send(cached.body);
        return;
      }
    }

    // Miss (or lookup failure) — let the request proceed to creditGate/the
    // real upstream call, but capture whatever `res.send` eventually gets
    // called with so a 2xx response can be written back to the cache.
    const originalSend = res.send.bind(res);
    res.send = (body?: any): Response => {
      if (res.statusCode >= 200 && res.statusCode < 300 && typeof body === "string") {
        const entry: CachedResponse = {
          status: res.statusCode,
          contentType: String(res.getHeader("Content-Type") ?? "application/json"),
          body,
          expiresAt: Date.now() + TTL_MS,
        };
        ref.set(entry).catch((error) => {
          logEvent("error", "responseCache.writeFailed", { requestId: req.requestId, uid, feature, error: String(error) });
        });
      }
      return originalSend(body);
    };

    logEvent("debug", "responseCache.miss", { requestId: req.requestId, uid, feature, cacheKey });
    next();
  };
}
