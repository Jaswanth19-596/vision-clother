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
 */
export function logEvent(level: Level, event: string, fields: Record<string, unknown> = {}): void {
  functionsLogger[level](event, fields);
}
