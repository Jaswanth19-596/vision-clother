import { Router } from "express";
import { z } from "zod";
import { openRouterApiKey } from "../secrets";
import type { AuthedRequest } from "../types";
import { logEvent, upstreamErrorSnippet } from "../logger";

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

openrouterChatRouter.post("/", async (req: AuthedRequest, res) => {
  const parsed = bodySchema.safeParse(req.body);
  if (!parsed.success) {
    logEvent("warn", "openrouterChat.invalidBody", { requestId: req.requestId, uid: req.uid });
    res.status(400).json({ error: "invalid_request_body" });
    return;
  }

  const start = Date.now();
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
    logEvent(upstream.ok ? "info" : "warn", "openrouterChat.upstreamResponse", {
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
    logEvent("error", "openrouterChat.upstreamUnreachable", {
      requestId: req.requestId,
      uid: req.uid,
      durationMs: Date.now() - start,
      error: String(error),
    });
    res.status(502).json({ error: "upstream_unreachable" });
  }
});
