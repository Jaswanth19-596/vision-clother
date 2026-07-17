import { Environment, SignedDataVerifier } from "@apple/app-store-server-library";
import { appleRootCertificates } from "./appleRootCerts";
import { logEvent } from "../logger";

/**
 * Verifies a StoreKit 2 transaction JWS (`VerificationResult.jwsRepresentation`)
 * and returns the fields `/iap/verify` needs. The signature check is the
 * security boundary of the whole credit system: without it, anyone holding a
 * valid Firebase ID token could mint credits from a hand-rolled JWS.
 *
 * Environment dispatch happens via an UNVERIFIED base64 peek at the payload's
 * `environment` field, and it must run BEFORE the token reaches any library
 * verifier: an Xcode-signed transaction (local `.storekit` testing) chains to
 * an Xcode-generated local root, not Apple's, so `SignedDataVerifier` would
 * reject it outright. The peek only selects a policy — it grants nothing.
 *
 * - "Sandbox": full signature verification against Apple's embedded roots.
 * - "Production": rejected until an App Store Connect record exists —
 *   `SignedDataVerifier` needs the app's `appAppleId` for production tokens,
 *   which doesn't exist pre-ASC. TODO(launch): construct a production
 *   verifier with the real appAppleId and remove this rejection.
 * - "Xcode": accepted decode-only, and ONLY when the
 *   `IAP_ALLOW_XCODE_UNVERIFIED=true` env var is set (functions .env; must
 *   stay off in production). The library is bypassed entirely on this path.
 *
 * Redaction: never log the JWS or the decoded payload wholesale — only
 * transactionId / productId / environment.
 */

const BUNDLE_ID = "com.Vision-clother";

export type IapVerifyErrorCode = "invalid_transaction" | "environment_not_supported";

export class IapVerifyError extends Error {
  readonly code: IapVerifyErrorCode;

  constructor(code: IapVerifyErrorCode, message: string) {
    super(message);
    this.code = code;
    this.name = "IapVerifyError";
  }
}

export interface VerifiedIapTransaction {
  transactionId: string;
  originalTransactionId: string;
  productId: string;
  /** Millis since epoch, straight from the JWS payload. */
  purchaseDate: number;
  environment: "Sandbox" | "Production" | "Xcode";
  /** True when the payload carries a `revocationDate` (refunded/revoked). */
  revoked: boolean;
}

interface RawTransactionPayload {
  transactionId?: unknown;
  originalTransactionId?: unknown;
  bundleId?: unknown;
  productId?: unknown;
  purchaseDate?: unknown;
  revocationDate?: unknown;
  environment?: unknown;
}

/**
 * Decodes the payload segment of a JWS without any signature check. Used for
 * the environment peek on every token, and as the full decode on the
 * gated Xcode path (where no Apple-rooted signature can exist).
 */
function decodePayloadUnverified(jws: string): RawTransactionPayload {
  const segments = jws.split(".");
  if (segments.length !== 3) {
    throw new IapVerifyError("invalid_transaction", "JWS does not have three segments");
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(Buffer.from(segments[1], "base64url").toString("utf8"));
  } catch {
    throw new IapVerifyError("invalid_transaction", "JWS payload is not valid base64url JSON");
  }
  if (typeof parsed !== "object" || parsed === null) {
    throw new IapVerifyError("invalid_transaction", "JWS payload is not an object");
  }
  return parsed as RawTransactionPayload;
}

function toVerified(payload: RawTransactionPayload, environment: "Sandbox" | "Production" | "Xcode"): VerifiedIapTransaction {
  const { transactionId, originalTransactionId, productId, purchaseDate, bundleId } = payload;
  if (typeof transactionId !== "string" || transactionId.length === 0) {
    throw new IapVerifyError("invalid_transaction", "missing transactionId");
  }
  if (typeof productId !== "string" || productId.length === 0) {
    throw new IapVerifyError("invalid_transaction", "missing productId");
  }
  if (bundleId !== BUNDLE_ID) {
    throw new IapVerifyError("invalid_transaction", "bundleId mismatch");
  }
  return {
    transactionId,
    originalTransactionId: typeof originalTransactionId === "string" && originalTransactionId.length > 0
      ? originalTransactionId
      : transactionId,
    productId,
    purchaseDate: typeof purchaseDate === "number" ? purchaseDate : 0,
    environment,
    revoked: payload.revocationDate !== undefined && payload.revocationDate !== null,
  };
}

let sandboxVerifier: SignedDataVerifier | undefined;

function getSandboxVerifier(): SignedDataVerifier {
  if (!sandboxVerifier) {
    sandboxVerifier = new SignedDataVerifier(
      appleRootCertificates(),
      false, // enableOnlineChecks: no OCSP network dependency inside a billing-critical request
      Environment.SANDBOX,
      BUNDLE_ID
    );
  }
  return sandboxVerifier;
}

export async function verifyIapJws(jws: string, requestId?: string): Promise<VerifiedIapTransaction> {
  const peeked = decodePayloadUnverified(jws);
  const environment = peeked.environment;

  switch (environment) {
    case "Sandbox": {
      let decoded;
      try {
        decoded = await getSandboxVerifier().verifyAndDecodeTransaction(jws);
      } catch (error) {
        logEvent("warn", "iap.verify.signatureRejected", { requestId, environment, error: String(error) });
        throw new IapVerifyError("invalid_transaction", "sandbox signature verification failed");
      }
      // Re-shape through the same field validation as every other path;
      // the library has already checked signature, chain, and bundleId.
      return toVerified(decoded as RawTransactionPayload, "Sandbox");
    }

    case "Production":
      // TODO(launch): needs the App Store Connect appAppleId — see doc comment.
      logEvent("warn", "iap.verify.productionUnsupported", { requestId });
      throw new IapVerifyError("environment_not_supported", "production verification not configured yet");

    case "Xcode": {
      if (process.env.IAP_ALLOW_XCODE_UNVERIFIED !== "true") {
        logEvent("warn", "iap.verify.xcodeRejected", { requestId });
        throw new IapVerifyError("environment_not_supported", "Xcode-signed transactions are not accepted");
      }
      // Deliberately loud: this path grants credits from an UNVERIFIED
      // payload and exists only for local .storekit testing.
      logEvent("warn", "iap.verify.xcodeUnverifiedAccepted", { requestId });
      return toVerified(peeked, "Xcode");
    }

    default:
      logEvent("warn", "iap.verify.unknownEnvironment", { requestId, environment: String(environment) });
      throw new IapVerifyError("invalid_transaction", "unknown environment");
  }
}
