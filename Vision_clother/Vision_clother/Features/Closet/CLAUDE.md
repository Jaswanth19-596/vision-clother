# Features/Closet Module

Wardrobe inventory grid, garment details, and upload ingestion.
- `ClosetView` renders categories matching the expanded slot structure (tops, bottoms, footwear, outerwear, headwear, accessories, bags).
- Displays item ratings (0-100 Bayesian shrinkage metrics computed dynamically in `ItemRatingScoring.swift`) as badges. Freshly added items show default neutral rating of 50.
- **Ingestion Pipeline:** Uses `JobQueueStore` to coordinate background isolation (Gemini API preprocessing to isolate garment -> on-device Vision foreground mask cutout) and tag metadata. Concurrency limit is uncapped at task start but queued.
- `ItemDetailView` allows direct editing of categories and attributes, bypassing auto-tag errors.
- **`ItemNotesSectionView` ("Your notes") is the correction surface for Item-Level Feedback.** Notes arrive from chips, from the user, and from an LLM reading their free-text outfit comment — and that last source can attribute a complaint to the wrong garment. Every note therefore shows its `ItemNoteSource` and is one tap from edit/delete; don't hide the source or make deletion harder to reach. Notes are snapshotted into a plain value before being handed to the editor sheet, since this view's own delete path invalidates the `@Model` object the sheet would still hold.
