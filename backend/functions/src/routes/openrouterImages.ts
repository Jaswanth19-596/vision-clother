import { Router } from "express";
import { z } from "zod";
import { openRouterApiKey } from "../secrets";
import type { AuthedRequest } from "../types";
import { logEvent, upstreamErrorSnippet } from "../logger";
import { getAllowedModels, isModelAllowed } from "../modelAllowlist";

const OPENROUTER_IMAGES_URL = "https://openrouter.ai/api/v1/images";

/** Loose top-level shape check only — see openrouterChat.ts for rationale. */
const bodySchema = z
  .object({
    model: z.string().min(1),
    prompt: z.string().min(1),
  })
  .passthrough();

export const openrouterImagesRouter = Router();

openrouterImagesRouter.post("/", async (req: AuthedRequest, res) => {
  const parsed = bodySchema.safeParse(req.body);
  if (!parsed.success) {
    logEvent("warn", "openrouterImages.invalidBody", { requestId: req.requestId, uid: req.uid });
    res.status(400).json({ error: "invalid_request_body" });
    return;
  }

  // `/openrouter/images` has no prefetch middleware mounted, so this always
  // takes the fresh-fetch branch (cache-backed, see modelAllowlist.ts) — see
  // openrouterChat.ts for the route that does have a prefetch.
  const allowedModels = await (req.modelAllowlistPrefetch ?? getAllowedModels(req.requestId));
  const isAllowed = isModelAllowed(parsed.data.model, allowedModels);
  if (!isAllowed) {
    logEvent("warn", "openrouterImages.modelNotAllowed", {
      requestId: req.requestId,
      uid: req.uid,
      model: parsed.data.model,
    });
    res.status(403).json({ error: "model_not_allowed" });
    return;
  }

  const start = Date.now();
  try {
    const upstream = await fetch(OPENROUTER_IMAGES_URL, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${openRouterApiKey.value()}`,
        "Content-Type": "application/json",
        "HTTP-Referer": "https://github.com/Antigravity",
        "X-Title": "Vision Clother iOS",
      },
      body: JSON.stringify(parsed.data),
    });

    const text = await upstream.text();
    logEvent(upstream.ok ? "info" : "warn", "openrouterImages.upstreamResponse", {
      requestId: req.requestId,
      uid: req.uid,
      model: parsed.data.model,
      status: upstream.status,
      durationMs: Date.now() - start,
      ...(upstream.ok ? {} : { upstreamErrorMessage: upstreamErrorSnippet(text) }),
    });
    res
      .status(upstream.status)
      .setHeader("Content-Type", upstream.headers.get("Content-Type") ?? "application/json")
      .send(text);
  } catch (error) {
    logEvent("error", "openrouterImages.upstreamUnreachable", {
      requestId: req.requestId,
      uid: req.uid,
      durationMs: Date.now() - start,
      error: String(error),
    });
    res.status(502).json({ error: "upstream_unreachable" });
  }
});
