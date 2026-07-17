import type { NextFunction, Response } from "express";
import { getAuth } from "firebase-admin/auth";
import type { AuthedRequest } from "../types";
import { logEvent } from "../logger";

/**
 * Rejects any request without a valid Firebase Auth ID token and attaches
 * the verified uid to the request for downstream rate limiting.
 */
export async function verifyAuth(
  req: AuthedRequest,
  res: Response,
  next: NextFunction
): Promise<void> {
  const header = req.header("Authorization");
  const token = header?.startsWith("Bearer ") ? header.slice("Bearer ".length) : undefined;
  if (!token) {
    logEvent("warn", "verifyAuth.missingToken", { requestId: req.requestId });
    res.status(401).json({ error: "missing_id_token" });
    return;
  }

  try {
    const decoded = await getAuth().verifyIdToken(token);
    req.uid = decoded.uid;
    req.isAnonymous = decoded.firebase?.sign_in_provider === "anonymous";
    logEvent("debug", "verifyAuth.ok", { requestId: req.requestId, uid: decoded.uid, isAnonymous: req.isAnonymous });
    next();
  } catch (error) {
    logEvent("warn", "verifyAuth.invalidToken", { requestId: req.requestId, error: String(error) });
    res.status(401).json({ error: "invalid_id_token" });
  }
}
