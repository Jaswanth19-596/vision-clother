import { logger as functionsLogger } from "firebase-functions";

type Level = "debug" | "info" | "warn" | "error";

/**
 * Structured wrapper over `firebase-functions/logger` (not plain `console.*`)
 * so every line lands in Cloud Logging with a real severity and searchable
 * fields, instead of one opaque text blob. `requestId` (see `app.ts`'s
 * request-logging middleware, which mints it and echoes it back as an
 * `X-Request-Id` response header) is the join key with the matching iOS-side
 * `AppLog` line for the same call — always pass it once it exists on the
 * request.
 *
 * Redaction rule: `fields` must never contain ID tokens, API keys, or raw
 * request/response bodies — ids, status codes, counts, and byte lengths only.
 * Exception: on a failed upstream call, pass the provider's own error message
 * through `upstreamErrorSnippet` first — that's the one signal that actually
 * distinguishes "bad key" from "bad request" from "provider outage", and
 * without it a 401 is indistinguishable from every other cause.
 */
export function logEvent(level: Level, event: string, fields: Record<string, unknown> = {}): void {
  functionsLogger[level](event, fields);
}

const MAX_UPSTREAM_ERROR_SNIPPET_LENGTH = 200;

/**
 * Bounded, safe-to-log summary of a failed upstream response body — the
 * provider's own `error.message`, not the raw body (which convention
 * forbids since it may echo back request content). Truncated so a
 * misbehaving provider can't blow up log line size.
 */
export function upstreamErrorSnippet(rawBody: string): string {
  try {
    const parsed = JSON.parse(rawBody) as { error?: { message?: string } | string; message?: string };
    const message =
      (typeof parsed.error === "object" ? parsed.error?.message : parsed.error) ?? parsed.message;
    if (typeof message === "string") return message.slice(0, MAX_UPSTREAM_ERROR_SNIPPET_LENGTH);
  } catch {
    // not JSON — fall through to a raw snippet
  }
  return rawBody.slice(0, MAX_UPSTREAM_ERROR_SNIPPET_LENGTH);
}
