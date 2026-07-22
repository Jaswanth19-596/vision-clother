import type { NextFunction, Response } from "express";
import { FieldValue, getFirestore } from "firebase-admin/firestore";
import type { AuthedRequest } from "../types";
import { logEvent } from "../logger";
import { refundQuota } from "./governance";
import type { QuotaFeature } from "./governance";

type LockStatus = "IN_PROGRESS" | "COMPLETED" | "FAILED";

interface CachedResponsePayload {
  status: number;
  contentType: string;
  body: string;
}

interface IdempotencyRecord {
  userId: string;
  status: LockStatus;
  responsePayload?: CachedResponsePayload;
  error?: string;
}

/**
 * Guards the quota-gated, real-money OpenRouter routes
 * (`/openrouter/recommend`, `/openrouter/tryon`, `/openrouter/images` — see
 * `app.ts`) against duplicate quota debits and duplicate paid upstream calls
 * when a client retries, the network is flaky, or the app backgrounds/gets
 * killed mid-request. Must run BEFORE `governanceGate`/`responseCache` in the
 * mount chain — a `COMPLETED` replay answers directly and never reaches
 * either.
 *
 * Mirrors `routes/iapVerify.ts`'s `processedTransactions` ledger pattern
 * (atomic Firestore-transaction lock keyed by a client-supplied id) rather
 * than `responseCache`'s content-hash cache: the caller declares "this is
 * one logical attempt" via `X-Idempotency-Key` instead of us inferring it
 * from a request-body hash, which is what lets a genuine retry of the exact
 * same attempt (same key) short-circuit while a deliberately different
 * request (new key — e.g. `OutfitRecommendationService`'s structured→
 * unstructured fallback, which changes the model and payload) is never
 * mistaken for one.
 *
 * Lock doc id `${uid}_${idempotencyKey}` lives in `idempotencyKeys/` —
 * `firestore.rules` denies all client reads/writes, same as every other
 * Admin-SDK-only collection this backend owns.
 *
 * A `FAILED` doc is treated the same as no doc at all (re-acquire the lock
 * and let the request through again) — that's what makes "the upstream call
 * genuinely failed, please retry with the same key" actually retryable
 * instead of wedging a key permanently after one bad attempt.
 */
export function idempotencyGate(feature: QuotaFeature) {
  return async (req: AuthedRequest, res: Response, next: NextFunction): Promise<void> => {
    const uid = req.uid;
    if (!uid) {
      res.status(401).json({ error: "missing_id_token" });
      return;
    }

    const idempotencyKey = req.header("X-Idempotency-Key");
    if (!idempotencyKey) {
      logEvent("warn", "idempotency.missingHeader", { requestId: req.requestId, uid, feature });
      res.status(400).json({ error: "Missing X-Idempotency-Key header" });
      return;
    }

    const db = getFirestore();
    const lockRef = db.collection("idempotencyKeys").doc(`${uid}_${idempotencyKey}`);

    let outcome: "proceed" | "completed" | "conflict";
    let cachedRecord: IdempotencyRecord | undefined;

    try {
      const result = await db.runTransaction(async (tx) => {
        const snap = await tx.get(lockRef);
        if (snap.exists) {
          const data = snap.data() as IdempotencyRecord;
          if (data.status === "COMPLETED") {
            return { outcome: "completed" as const, record: data };
          }
          if (data.status === "IN_PROGRESS") {
            return { outcome: "conflict" as const, record: data };
          }
          // FAILED — fall through and re-acquire below, overwriting the
          // stale FAILED record so a successful retry starts clean.
        }

        tx.set(lockRef, {
          userId: uid,
          status: "IN_PROGRESS" satisfies LockStatus,
          createdAt: FieldValue.serverTimestamp(),
          updatedAt: FieldValue.serverTimestamp(),
        });
        return { outcome: "proceed" as const };
      });
      outcome = result.outcome;
      cachedRecord = "record" in result ? result.record : undefined;
    } catch (error) {
      // Fail closed — same posture as iapVerify.ts. Letting the request
      // through on a Firestore hiccup here would defeat the entire point of
      // this guard (duplicate paid calls / duplicate quota debits).
      logEvent("error", "idempotency.lockFailClosed", { requestId: req.requestId, uid, feature, idempotencyKey, error: String(error) });
      res.status(503).json({ error: "temporarily_unavailable" });
      return;
    }

    if (outcome === "completed") {
      const payload = cachedRecord?.responsePayload;
      logEvent("info", "idempotency.replay", { requestId: req.requestId, uid, feature, idempotencyKey });
      if (payload) {
        res.status(payload.status).setHeader("Content-Type", payload.contentType).send(payload.body);
      } else {
        // Shouldn't happen (COMPLETED is only ever written alongside a
        // payload below) — answer something rather than hanging.
        res.status(200).json({});
      }
      return;
    }

    if (outcome === "conflict") {
      logEvent("info", "idempotency.conflict", { requestId: req.requestId, uid, feature, idempotencyKey });
      res.status(409).json({ error: "Request already in progress" });
      return;
    }

    // PROCEED — lock acquired. Let governanceGate debit and the route call
    // upstream, then finalize the lock from whatever status code the
    // response eventually carries. Wrapping `res.send` (not `res.on("finish")`)
    // because a COMPLETED replay must be able to reproduce the exact original
    // status/content-type/body, not just know it was "a 2xx".
    const originalSend = res.send.bind(res);
    res.send = (body?: any): Response => {
      const success = res.statusCode >= 200 && res.statusCode < 300;
      const bodyText = typeof body === "string" ? body : JSON.stringify(body ?? {});

      const finalize = success
        ? lockRef.set(
            {
              status: "COMPLETED" satisfies LockStatus,
              responsePayload: {
                status: res.statusCode,
                contentType: String(res.getHeader("Content-Type") ?? "application/json"),
                body: bodyText,
              } satisfies CachedResponsePayload,
              updatedAt: FieldValue.serverTimestamp(),
            },
            { merge: true }
          )
        : lockRef.set(
            {
              status: "FAILED" satisfies LockStatus,
              error: `HTTP ${res.statusCode}`,
              updatedAt: FieldValue.serverTimestamp(),
            },
            { merge: true }
          );

      finalize.catch((error) => {
        logEvent("error", "idempotency.finalizeFailed", { requestId: req.requestId, uid, feature, idempotencyKey, error: String(error) });
      });

      if (!success && req.quotaDebit) {
        refundQuota(req).catch((error) => {
          logEvent("error", "idempotency.refundFailed", { requestId: req.requestId, uid, feature, idempotencyKey, error: String(error) });
        });
      }

      return originalSend(body);
    };

    next();
  };
}
