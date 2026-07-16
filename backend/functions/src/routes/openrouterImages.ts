import { Router } from "express";
import { z } from "zod";
import { openRouterApiKey } from "../secrets";

const OPENROUTER_IMAGES_URL = "https://openrouter.ai/api/v1/images";

/** Loose top-level shape check only — see openrouterChat.ts for rationale. */
const bodySchema = z
  .object({
    model: z.string().min(1),
    prompt: z.string().min(1),
  })
  .passthrough();

export const openrouterImagesRouter = Router();

openrouterImagesRouter.post("/", async (req, res) => {
  const parsed = bodySchema.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: "invalid_request_body" });
    return;
  }

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
    res
      .status(upstream.status)
      .setHeader("Content-Type", upstream.headers.get("Content-Type") ?? "application/json")
      .send(text);
  } catch {
    res.status(502).json({ error: "upstream_unreachable" });
  }
});
