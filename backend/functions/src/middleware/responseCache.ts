import type { NextFunction, Response } from "express";
import { createHash } from "crypto";
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

/**
 * Must run after verifyAuth (needs req.uid) and *before* governanceGate for
 * `feature` in app.ts's mount chain — a cache hit responds directly and
 * returns without calling `next()`, which is what keeps a hit from ever
 * reaching governanceGate or the upstream OpenRouter fetch (zero quota charged,
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
 */
export function responseCache(feature: string) {
  return async (req: AuthedRequest, res: Response, next: NextFunction): Promise<void> => {
    const uid = req.uid;
    if (!uid) {
      next();
      return;
    }

    const cacheKey = createHash("sha256").update(JSON.stringify(req.body)).digest("hex");
    const ref = getFirestore().collection("users").doc(uid).collection("responseCache").doc(cacheKey);

    try {
      const snap = await ref.get();
      const cached = snap.data() as CachedResponse | undefined;
      if (cached && cached.expiresAt > Date.now()) {
        logEvent("info", "responseCache.hit", { requestId: req.requestId, uid, feature, cacheKey });
        res.status(cached.status).setHeader("Content-Type", cached.contentType).send(cached.body);
        return;
      }
    } catch (error) {
      logEvent("error", "responseCache.lookupFailOpen", { requestId: req.requestId, uid, feature, error: String(error) });
    }

    // Miss (or lookup failure) — let the request proceed to governanceGate/the
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
