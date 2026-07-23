import { getFirestore } from "firebase-admin/firestore";
import { logEvent } from "./logger";

/**
 * Exact-match allowlist of OpenRouter model IDs `openrouterChat.ts` and
 * `openrouterImages.ts` are permitted to proxy with the project's own API
 * key. Closes a billing-abuse gap: those routes previously accepted any
 * non-empty `model` string, and combined with free/unlimited Firebase
 * anonymous guest accounts (`AuthService.ensureGuestSession()`), a scripted
 * caller could pick the most expensive model OpenRouter offers.
 *
 * Backed by Firestore (`config/openrouterModels`) so ops can add a newly
 * adopted model (`Vision_clother/Config/ModelConfig.swift` is
 * Remote-Config-hotfixable with no app rebuild) without a backend redeploy —
 * write `{ allowedModels: string[] }` to that doc via the Firebase Console
 * or an Admin SDK/MCP tool. `DEFAULT_ALLOWED_MODELS` below is the
 * fallback-of-last-resort so this works correctly with zero manual seeding;
 * keep it in sync by hand with `ModelConfig.swift`'s active + documented
 * alternates whenever a new model is adopted client-side.
 */
const DEFAULT_ALLOWED_MODELS: readonly string[] = [
  "google/gemini-3.1-flash-lite",
  "openai/gpt-5-mini",
  "minimax/minimax-m3",
  "google/gemini-3.1-flash-lite-image",
  "qwen/qwen3-vl-30b-a3b-instruct",
  "bytedance-seed/seedream-4.5",
  "google/gemini-2.5-flash-image",
];

/**
 * This config changes at human/ops pace, not per-request, so it doesn't
 * need `middleware/governance.ts`'s aggressive 20s TTL — 5 minutes still
 * reads as "instant" at ops timescale while cutting Firestore reads
 * substantially under steady traffic on a warm instance.
 */
const CACHE_TTL_MS = 5 * 60_000;

interface AllowlistCache {
  cachedAt: number;
  models: readonly string[];
}

/** Module-scope — survives across requests on the same warm instance, never shared cross-instance. */
let cache: AllowlistCache | null = null;

function isFresh(entry: AllowlistCache): boolean {
  return Date.now() - entry.cachedAt < CACHE_TTL_MS;
}

async function fetchAllowedModels(requestId: string | undefined): Promise<readonly string[]> {
  try {
    const snapshot = await getFirestore().collection("config").doc("openrouterModels").get();
    const data = snapshot.data();
    const allowedModels = data?.allowedModels;
    if (!Array.isArray(allowedModels) || allowedModels.length === 0 || !allowedModels.every((m) => typeof m === "string")) {
      logEvent("warn", "modelAllowlist.usingDefaults", { requestId, reason: "doc_missing_or_malformed" });
      return DEFAULT_ALLOWED_MODELS;
    }
    return allowedModels as readonly string[];
  } catch (error) {
    logEvent("warn", "modelAllowlist.firestoreUnreachable", { requestId, error: String(error) });
    // Prefer a stale-but-previously-valid list over the hardcoded defaults —
    // a transient Firestore blip shouldn't silently un-allow a model ops
    // added between deploys. Only fall through to the hardcoded defaults
    // when there's no prior cache at all (cold start during an outage).
    if (cache) return cache.models;
    return DEFAULT_ALLOWED_MODELS;
  }
}

/** Returns the current allowlist, using the warm-instance cache when fresh. */
export async function getAllowedModels(requestId: string | undefined): Promise<readonly string[]> {
  if (cache && isFresh(cache)) return cache.models;
  const models = await fetchAllowedModels(requestId);
  cache = { cachedAt: Date.now(), models };
  return models;
}

/** True if `model` exactly matches an entry in the current allowlist. */
export function isModelAllowed(model: string, allowedModels: readonly string[]): boolean {
  return allowedModels.includes(model);
}

/** Convenience wrapper for route handlers: one call, one `if`. */
export async function assertModelAllowed(model: string, requestId: string | undefined): Promise<boolean> {
  const allowedModels = await getAllowedModels(requestId);
  return isModelAllowed(model, allowedModels);
}
