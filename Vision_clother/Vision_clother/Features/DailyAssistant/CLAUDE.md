# Features/DailyAssistant Module

Scenario-based outfit recommendations chatbot and outfit carousel.
- `DailyAssistantView` drives scenario-based free-text prompts, mapping user queries to LLM recommendations.
- **Outfit Carousel:** Renders recommended outfits in a horizontal orthogonal `ScrollView` with `.viewAligned` scroll targeting to eliminate horizontal/vertical gesture conflicts with the outer message history stack. Card count is strictly derived from LLM output.
- **Action Permanent State:** Once queued via the "How does it look on me?" button, the combination ID is added to a persistent `queuedOutfitIDs` set so the button label locks to "Added to queue ✓". Swiping cards changes the focus button state without clearing previous state.
- Clarification chips show intermediate prompt refinements and block double-taps by instantly keying off selection state.
- **Wardrobe/Insights Q&A (2026-07-20, plumbing revised 2026-07-21):** a free-text turn that reads as a question (`Domain/QuestionIntentHeuristic.swift`) is tried against `StylistQAService` (a separate, smaller call — see `Services/CLAUDE.md`) before the ordinary recommendation flow. A confirmed answer renders as a plain `.answer` chat bubble, not the outfit carousel; anything else falls through to `resolveOutfits`. The wardrobe snapshot + catalog build is fetched once in `resolveTurn` and threaded through both calls as `PrefetchedWardrobeContext` — `resolveOutfits` only redoes that fetch/build itself when called on the non-question fast path (no heuristic match).
