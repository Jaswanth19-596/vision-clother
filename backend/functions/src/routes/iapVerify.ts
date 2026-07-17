import { Router } from "express";
import { getFirestore } from "firebase-admin/firestore";
import { z } from "zod";
import type { AuthedRequest } from "../types";
import { logEvent } from "../logger";
import { BALANCE_FIELD, PRODUCT_GRANTS } from "../iap/products";
import { IapVerifyError, verifyIapJws } from "../iap/verifyTransaction";

export const iapVerifyRouter = Router();

const bodySchema = z.object({
  jws: z.string().min(1).max(10_000),
});

/**
 * POST /iap/verify — the second deliberate "business logic" exception to
 * this backend's passthrough posture (see app.ts; the first is
 * /account/delete). StoreKit 2 consumable purchases are verified and
 * ledgered here because the credit balance lives in the server-only-write
 * `users/{uid}/meta/usage` doc: only the Admin SDK can mutate it, which is
 * exactly what makes the balance trustworthy to quota.ts.
 *
 * Contract with the iOS client (`Services/StoreKitPaymentManager.swift`):
 * the client calls `Transaction.finish()` ONLY after this route returns
 * `granted: true` (including `alreadyProcessed` replays) or
 * `granted: false, reason: "revoked"`. Anything else leaves the StoreKit
 * transaction unfinished, so StoreKit redelivers it and this route runs
 * again — which is why the `processedTransactions/{transactionId}` ledger
 * check lives INSIDE the same Firestore transaction as the balance
 * increment: redelivery (or a replayed JWS from any source) reads the
 * ledger doc and grants nothing, making retries safe and double-spend
 * impossible.
 *
 * Guests cannot purchase: an anonymous uid is destroyed by sign-out or
 * reinstall, which would orphan paid credits — the client hides the store
 * from guests and this 403 is the backstop.
 *
 * Fails CLOSED on Firestore errors (unlike quotaGate's linked-account
 * fail-open): granting credits is not availability-critical, and the
 * client's unfinished transaction retries later.
 */
iapVerifyRouter.post("/", async (req: AuthedRequest, res) => {
  const uid = req.uid;
  if (!uid) {
    res.status(401).json({ error: "missing_id_token" });
    return;
  }

  if (req.isAnonymous) {
    logEvent("info", "iap.verify.signInRequired", { requestId: req.requestId, uid });
    res.status(403).json({ error: "sign_in_required" });
    return;
  }

  const parsed = bodySchema.safeParse(req.body);
  if (!parsed.success) {
    logEvent("warn", "iap.verify.invalidRequest", { requestId: req.requestId, uid });
    res.status(400).json({ error: "invalid_request" });
    return;
  }

  const start = Date.now();
  logEvent("info", "iap.verify.start", { requestId: req.requestId, uid, jwsLength: parsed.data.jws.length });

  let transaction;
  try {
    transaction = await verifyIapJws(parsed.data.jws, req.requestId);
  } catch (error) {
    if (error instanceof IapVerifyError) {
      logEvent("warn", "iap.verify.invalid", { requestId: req.requestId, uid, code: error.code, message: error.message });
      res.status(error.code === "environment_not_supported" ? 403 : 400).json({ error: error.code });
      return;
    }
    logEvent("error", "iap.verify.verifierFailed", { requestId: req.requestId, uid, error: String(error) });
    res.status(400).json({ error: "invalid_transaction" });
    return;
  }

  const grant = PRODUCT_GRANTS[transaction.productId];
  if (!grant) {
    // A real, signature-valid purchase for a product this table doesn't
    // know is catalog drift between App Store Connect / .storekit and
    // PRODUCT_GRANTS — an error-level signal, not user noise.
    logEvent("error", "iap.verify.unknownProduct", {
      requestId: req.requestId,
      uid,
      productId: transaction.productId,
      transactionId: transaction.transactionId,
    });
    res.status(400).json({ error: "unknown_product" });
    return;
  }

  const db = getFirestore();
  const processedRef = db.collection("processedTransactions").doc(transaction.transactionId);
  const usageRef = db.collection("users").doc(uid).collection("meta").doc("usage");
  const balanceField = BALANCE_FIELD[grant.creditType];

  try {
    if (transaction.revoked) {
      // Refunded before we ever saw it: record it for audit, grant nothing,
      // and tell the client to finish the transaction so it stops retrying.
      await processedRef.set({
        uid,
        productId: transaction.productId,
        creditType: grant.creditType,
        amount: 0,
        transactionId: transaction.transactionId,
        originalTransactionId: transaction.originalTransactionId,
        purchaseDate: transaction.purchaseDate,
        environment: transaction.environment,
        revoked: true,
        processedAt: Date.now(),
        requestId: req.requestId ?? null,
      });
      logEvent("warn", "iap.verify.revoked", {
        requestId: req.requestId,
        uid,
        productId: transaction.productId,
        transactionId: transaction.transactionId,
        environment: transaction.environment,
      });
      res.status(200).json({ granted: false, reason: "revoked" });
      return;
    }

    const result = await db.runTransaction(async (tx) => {
      const [processedSnap, usageSnap] = await Promise.all([tx.get(processedRef), tx.get(usageRef)]);

      if (processedSnap.exists) {
        return { alreadyProcessed: true as const, newBalance: undefined };
      }

      const usageData = usageSnap.exists ? usageSnap.data() : undefined;
      const newBalance = ((usageData?.[balanceField] as number) ?? 0) + grant.amount;

      // Field-scoped merge write: quota.ts owns periodKey/counts and may be
      // committing concurrently in its own transaction — this side must
      // never touch those fields. If the usage doc doesn't exist yet the
      // merge-set creates it with just the balance, which quota.ts already
      // tolerates (missing count fields read as 0).
      tx.set(
        usageRef,
        { [balanceField]: newBalance, updatedAt: Date.now() },
        { merge: true }
      );
      tx.set(processedRef, {
        uid,
        productId: transaction.productId,
        creditType: grant.creditType,
        amount: grant.amount,
        transactionId: transaction.transactionId,
        originalTransactionId: transaction.originalTransactionId,
        purchaseDate: transaction.purchaseDate,
        environment: transaction.environment,
        revoked: false,
        processedAt: Date.now(),
        requestId: req.requestId ?? null,
      });
      return { alreadyProcessed: false as const, newBalance };
    });

    if (result.alreadyProcessed) {
      logEvent("info", "iap.verify.duplicate", {
        requestId: req.requestId,
        uid,
        productId: transaction.productId,
        transactionId: transaction.transactionId,
        durationMs: Date.now() - start,
      });
      res.status(200).json({ granted: true, alreadyProcessed: true });
      return;
    }

    logEvent("info", "iap.verify.granted", {
      requestId: req.requestId,
      uid,
      productId: transaction.productId,
      transactionId: transaction.transactionId,
      creditType: grant.creditType,
      amount: grant.amount,
      newBalance: result.newBalance,
      environment: transaction.environment,
      durationMs: Date.now() - start,
    });
    res.status(200).json({
      granted: true,
      creditType: grant.creditType,
      amount: grant.amount,
      newBalance: result.newBalance,
      alreadyProcessed: false,
    });
  } catch (error) {
    // Fail closed — see doc comment. The client's unfinished transaction
    // is the durable retry state; nothing has been granted or ledgered if
    // the transaction aborted.
    logEvent("error", "iap.verify.failClosed", {
      requestId: req.requestId,
      uid,
      transactionId: transaction.transactionId,
      error: String(error),
    });
    res.status(503).json({ error: "temporarily_unavailable" });
  }
});
