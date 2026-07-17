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
 *
 * On a Firestore hiccup: fails open for linked accounts (an outage
 * shouldn't take down the whole AI feature set for real users) but fails
 * closed for anonymous/guest requests, since guest accounts are free to
 * mint and are the actual abuse vector this guardrail exists for — see
 * `quota.ts`'s matching posture.
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
    if (req.isAnonymous) {
      logEvent("error", "rateLimit.failClosed", { requestId: req.requestId, uid, error: String(error) });
      res.status(503).json({ error: "temporarily_unavailable" });
      return;
    }
    // Firestore hiccup shouldn't take down the proxy for a linked
    // account — fail open on the rate limiter itself.
    logEvent("error", "rateLimit.failOpen", { requestId: req.requestId, uid, error: String(error) });
    next();
  }
}
