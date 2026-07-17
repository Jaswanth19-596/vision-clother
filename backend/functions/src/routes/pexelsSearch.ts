import { Router } from "express";
import { z } from "zod";
import { pexelsApiKey } from "../secrets";
import type { AuthedRequest } from "../types";
import { logEvent, upstreamErrorSnippet } from "../logger";

const PEXELS_SEARCH_URL = "https://api.pexels.com/v1/search";

const querySchema = z.object({
  query: z.string().min(1),
  per_page: z.string().optional(),
  page: z.string().optional(),
});

export const pexelsSearchRouter = Router();

pexelsSearchRouter.get("/", async (req: AuthedRequest, res) => {
  const parsed = querySchema.safeParse(req.query);
  if (!parsed.success) {
    logEvent("warn", "pexelsSearch.invalidQuery", { requestId: req.requestId, uid: req.uid });
    res.status(400).json({ error: "invalid_query_params" });
    return;
  }

  const url = new URL(PEXELS_SEARCH_URL);
  url.searchParams.set("query", parsed.data.query);
  if (parsed.data.per_page) url.searchParams.set("per_page", parsed.data.per_page);
  if (parsed.data.page) url.searchParams.set("page", parsed.data.page);

  const start = Date.now();
  try {
    // Pexels expects the raw key with no "Bearer " prefix.
    const upstream = await fetch(url, {
      headers: { Authorization: pexelsApiKey.value() },
    });

    const text = await upstream.text();
    logEvent(upstream.ok ? "info" : "warn", "pexelsSearch.upstreamResponse", {
      requestId: req.requestId,
      uid: req.uid,
      query: parsed.data.query,
      status: upstream.status,
      durationMs: Date.now() - start,
      ...(upstream.ok ? {} : { upstreamErrorMessage: upstreamErrorSnippet(text) }),
    });
    res
      .status(upstream.status)
      .setHeader("Content-Type", upstream.headers.get("Content-Type") ?? "application/json")
      .send(text);
  } catch (error) {
    logEvent("error", "pexelsSearch.upstreamUnreachable", {
      requestId: req.requestId,
      uid: req.uid,
      durationMs: Date.now() - start,
      error: String(error),
    });
    res.status(502).json({ error: "upstream_unreachable" });
  }
});
