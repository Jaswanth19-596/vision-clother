import type { NextFunction, Response } from "express";
import { getFirestore } from "firebase-admin/firestore";
import type { AuthedRequest } from "../types";
import { logEvent } from "../logger";

/** Coarse per-user daily quota, shared across all three proxy routes. */
const DAILY_REQUEST_LIMIT = 500;

function todayKey(): string {
  return new Date().toISOString().slice(0, 10); // YYYY-MM-DD, UTC
}

/**
 * Must run after verifyAuth (needs req.uid). Atomically increments a
 * per-uid-per-day counter in Firestore and rejects once DAILY_REQUEST_LIMIT
 * is exceeded — cheap abuse guardrail, not a billing/metering system.
 */
export async function rateLimit(
  req: AuthedRequest,
  res: Response,
  next: NextFunction
): Promise<void> {
  const uid = req.uid;
  if (!uid) {
    res.status(401).json({ error: "missing_id_token" });
    return;
  }

  const docRef = getFirestore().collection("rateLimits").doc(`${uid}_${todayKey()}`);

  try {
    const exceeded = await getFirestore().runTransaction(async (tx) => {
      const snap = await tx.get(docRef);
      const count = (snap.exists ? (snap.data()?.count as number) : 0) ?? 0;
      if (count >= DAILY_REQUEST_LIMIT) {
        return true;
      }
      tx.set(docRef, { count: count + 1, updatedAt: Date.now() }, { merge: true });
      return false;
    });

    if (exceeded) {
      logEvent("warn", "rateLimit.exceeded", { requestId: req.requestId, uid, limit: DAILY_REQUEST_LIMIT });
      res.status(429).json({ error: "rate_limit_exceeded" });
      return;
    }
    next();
  } catch (error) {
    // Firestore hiccup shouldn't take down the proxy — fail open on the
    // rate limiter itself, since App Check + Auth already gate access.
    logEvent("error", "rateLimit.failOpen", { requestId: req.requestId, uid, error: String(error) });
    next();
  }
}
