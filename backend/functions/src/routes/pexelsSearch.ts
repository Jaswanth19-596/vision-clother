import { Router } from "express";
import { z } from "zod";
import { pexelsApiKey } from "../secrets";

const PEXELS_SEARCH_URL = "https://api.pexels.com/v1/search";

const querySchema = z.object({
  query: z.string().min(1),
  per_page: z.string().optional(),
  page: z.string().optional(),
});

export const pexelsSearchRouter = Router();

pexelsSearchRouter.get("/", async (req, res) => {
  const parsed = querySchema.safeParse(req.query);
  if (!parsed.success) {
    res.status(400).json({ error: "invalid_query_params" });
    return;
  }

  const url = new URL(PEXELS_SEARCH_URL);
  url.searchParams.set("query", parsed.data.query);
  if (parsed.data.per_page) url.searchParams.set("per_page", parsed.data.per_page);
  if (parsed.data.page) url.searchParams.set("page", parsed.data.page);

  try {
    // Pexels expects the raw key with no "Bearer " prefix.
    const upstream = await fetch(url, {
      headers: { Authorization: pexelsApiKey.value() },
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
