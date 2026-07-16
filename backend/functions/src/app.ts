import express from "express";
import { verifyAuth } from "./middleware/verifyAuth";
import { rateLimit } from "./middleware/rateLimit";
import { openrouterChatRouter } from "./routes/openrouterChat";
import { openrouterImagesRouter } from "./routes/openrouterImages";
import { pexelsSearchRouter } from "./routes/pexelsSearch";

/**
 * Every route is: verify Firebase Auth -> rate limit -> forward to the
 * provider verbatim. No business logic lives past this point — see
 * docs/backend/conventions.md. App Check is deferred (needs a paid Apple
 * Developer account for App Attest) — see docs/decisions/resolved-v1.md.
 */
export function buildApp(): express.Express {
  const app = express();
  app.use(express.json({ limit: "15mb" })); // headroom over the ~10MB post-downscale image payloads

  app.use(verifyAuth, rateLimit);

  app.use("/openrouter/chat", openrouterChatRouter);
  app.use("/openrouter/images", openrouterImagesRouter);
  app.use("/pexels/search", pexelsSearchRouter);

  return app;
}
