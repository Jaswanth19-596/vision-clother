import { Router } from "express";
import { z } from "zod";
import { openRouterApiKey } from "../secrets";

const OPENROUTER_CHAT_URL = "https://openrouter.ai/api/v1/chat/completions";

/**
 * Loose top-level shape check only — the iOS client already owns the full
 * message/schema construction (Config/ModelConfig.swift's Prompts + each
 * service's JSON schema). Deep validation here would duplicate that
 * business logic server-side, which docs/backend/conventions.md rules out.
 */
const bodySchema = z
  .object({
    model: z.string().min(1),
    messages: z.array(z.unknown()).min(1),
  })
  .passthrough();

export const openrouterChatRouter = Router();

openrouterChatRouter.post("/", async (req, res) => {
  const parsed = bodySchema.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: "invalid_request_body" });
    return;
  }

  try {
    const upstream = await fetch(OPENROUTER_CHAT_URL, {
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
