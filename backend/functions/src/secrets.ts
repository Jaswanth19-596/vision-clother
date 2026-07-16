import { defineSecret } from "firebase-functions/params";

/**
 * Provider keys, injected at runtime by Cloud Functions secret manager —
 * never read from an .env file or committed anywhere. Set once via:
 *   firebase functions:secrets:set OPENROUTER_API_KEY
 *   firebase functions:secrets:set PEXELS_API_KEY
 */
export const openRouterApiKey = defineSecret("OPENROUTER_API_KEY");
export const pexelsApiKey = defineSecret("PEXELS_API_KEY");
