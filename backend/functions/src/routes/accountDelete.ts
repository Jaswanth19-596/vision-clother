import { Router } from "express";
import { getFirestore } from "firebase-admin/firestore";
import { getStorage } from "firebase-admin/storage";
import { getAuth } from "firebase-admin/auth";
import type { AuthedRequest } from "../types";
import { logEvent } from "../logger";

export const accountDeleteRouter = Router();

/**
 * Deliberate exception to this file's usual "no business logic past
 * verifyAuth" posture (see app.ts) — bulk cross-collection Firestore
 * deletion, a Storage prefix wipe, and deleting the Firebase Auth user
 * itself all require Admin SDK privileges the client can never safely hold,
 * and doing this as N separate client-side deletes under security rules
 * would be slow and easy to leave half-finished on a dropped connection.
 * `req.uid` comes from `verifyAuth`'s already-verified ID token — never a
 * client-supplied parameter, so there's no way to delete another account.
 *
 * Order matters: Firestore is the source of truth, so a failure there
 * aborts before anything else runs and the user's credential is left
 * intact, so a retry is possible. Storage cleanup is best-effort (logged,
 * not fatal) — a failed file delete just leaves orphaned, otherwise
 * inaccessible objects under a uid nobody can authenticate as once the Auth
 * user is gone; same "documented, not reconciled" posture as this backend's
 * existing `meta/itemCounts` drift note. Auth-user deletion runs last so a
 * failure there still leaves the (by then empty) account in a retryable
 * state.
 */
accountDeleteRouter.post("/", async (req: AuthedRequest, res) => {
  const uid = req.uid;
  if (!uid) {
    res.status(401).json({ error: "missing_id_token" });
    return;
  }

  const start = Date.now();
  logEvent("info", "accountDelete.start", { requestId: req.requestId, uid });

  try {
    await getFirestore().recursiveDelete(getFirestore().collection("users").doc(uid));
  } catch (error) {
    logEvent("error", "accountDelete.firestoreFailed", {
      requestId: req.requestId,
      uid,
      durationMs: Date.now() - start,
      error: String(error),
    });
    res.status(500).json({ error: "firestore_delete_failed" });
    return;
  }

  try {
    await getStorage().bucket().deleteFiles({ prefix: `users/${uid}/` });
  } catch (error) {
    // Non-fatal — see doc comment above.
    logEvent("warn", "accountDelete.storageFailed", {
      requestId: req.requestId,
      uid,
      error: String(error),
    });
  }

  try {
    await getAuth().deleteUser(uid);
  } catch (error) {
    logEvent("error", "accountDelete.authFailed", {
      requestId: req.requestId,
      uid,
      durationMs: Date.now() - start,
      error: String(error),
    });
    res.status(500).json({ error: "auth_delete_failed" });
    return;
  }

  logEvent("info", "accountDelete.finish", { requestId: req.requestId, uid, durationMs: Date.now() - start });
  res.status(200).json({ deleted: true });
});
