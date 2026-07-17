# Features/Closet Module

Wardrobe inventory grid, garment details, and upload ingestion.
- `ClosetView` renders categories matching the expanded slot structure (tops, bottoms, footwear, outerwear, headwear, accessories, bags).
- Displays item ratings (0-100 Bayesian shrinkage metrics computed dynamically in `ItemRatingScoring.swift`) as badges. Freshly added items show default neutral rating of 50.
- **Ingestion Pipeline:** Uses `JobQueueStore` to coordinate background isolation (Gemini API preprocessing to isolate garment -> on-device Vision foreground mask cutout) and tag metadata. Concurrency limit is uncapped at task start but queued.
- `ItemDetailView` allows direct editing of categories and attributes, bypassing auto-tag errors.
