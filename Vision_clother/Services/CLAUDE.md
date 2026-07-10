# Services Layer

All services implement a protocol-first pattern.
- API clients use raw URLSession (no SDK) with typed Codable request/response.
- OpenRouter calls: model is `minimax/minimax-m3`, always try `response_format: json_schema` first, fall back to prompt-embedded schema.
- Fal calls: async submit → poll queue with bounded poll budget. One garment per call, chain for multi-garment outfits.
- API keys come from Secrets.plist (see Config/ directory).
