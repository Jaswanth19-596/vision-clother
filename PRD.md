Product Requirements Document (PRD)
Vision Clother
An AI-Driven Personal Stylist & Visual Try-On Wardrobe Assistant
Author: Jaswanth Mada

Target Dev Target: Claude Code / Agentic Workflows

Version: 1.0

Date: July 2026

Platform Stack: Mobile-first (iOS Native/React Native), LLM + Deterministic Rules Engine

1. Executive Summary & Product Vision
1.1 Problem Statement
Most individuals own an ample volume of clothing items but struggle consistently to choose the right combinations for any given occasion. Traditional wardrobe planning is manual, time-consuming, and prone to visual mismatches. Approximately 80% of the time, the resulting outfit is suboptimal or aesthetically mismatched for the specific setting. Existing digital closet tools fail because they act as basic CRUD inventory apps tracking recall ("what do I own") instead of resolving combinatorics ("what goes together") or providing accurate aesthetic judgment ("does this look good on me").

1.2 Core Product Vision
Vision Clother is an interactive, AI-driven personal stylist app designed to answer the daily question: "What should I wear today?" It converts text-based situational context into accurate, personalized outfit matches using an innovative Hybrid Architecture: an LLM extracts constraints, a fast deterministic engine filters inventory rules, and a visual generative model presents an instantaneous digital try-on canvas. The ultimate metric of success is reducing the time-to-outfit to seconds while raising visual confidence to 100%.

2. System Architecture & High-Level Pipeline
To maximize speed, guarantee strict formatting constraints, and control API token spend, the application deliberately decouples human contextual interpretation from database processing logic.

⚠️ Architecture Rule (revised 2026-07-10): The LLM is the primary outfit recommender. It receives a *bounded* catalog of wardrobe item descriptions (never raw images at recommendation time) — never the unbounded raw inventory — plus the user's style profile, weather, and color-theory guidance, and returns outfit picks by item ID. A deterministic validator/fallback engine guarantees every surfaced outfit references real, correctly-slotted, owned items, and guarantees the app still works with no LLM available. See §2.1a and §3.7.

2.1 The 4-Stage Execution Flow (fallback path)
This is the deterministic safety net, used when the primary LLM-recommender path (§2.1a) is unavailable or returns nothing valid.

Intent Extraction Layer (LLM API): User passes fuzzy text ("Tech interview at Morgan Stanley") along with localized weather parameters. The LLM translates this text into a strict JSON payload containing constraint fields (formality range, seasonal tags, color palettes).

Candidate Retrieval Layer (Local Database Query): The local system converts the JSON criteria into SQL/NoSQL parameters, retrieving all valid inventory candidates isolated by structural slot (Tops, Bottoms, Footwear, Outerwear).

Permutation & Heuristic Engine (Deterministic Backend Code): Local code computes the cross-product combinations of matching clothes and evaluates them using absolute stylistic priors (color count ceilings, formality delta constraints, and pattern clashing logic, including hue/undertone-based color theory — see §3.4).

Visual Generation Canvas (Image Generation Pipeline): The top-performing flatlay options are presented to the user. Upon tapping "How does it look on me?", the pipeline composites the chosen clothing layer over the user's base onboarding image to deliver a tailored, context-aware visual preview.

2.1a The Primary Execution Flow (LLM-as-Recommender)
1. Catalog Build (Local, Deterministic): `Domain/WardrobeCatalogBuilder` converts the on-device inventory into a bounded, size-capped list of compact item descriptions (id, slot, formality, color category + hex, undertone, pattern, seasonality, fabric weight, ≤140-char description). Ghost Elements are excluded. Oversized inventories are deterministically prefiltered/sampled before serialization.
2. Recommendation Call (LLM API): The user's free-text prompt, the bounded catalog, the derived User Style Profile (§3.8), current weather, and color-theory guidance are sent to the Recommendation LLM (see §3.7), which returns up to 5 candidate outfits referencing catalog item IDs plus a short rationale per outfit.
3. Validation (Local, Deterministic): `Domain/OutfitRecommendationValidator` hard-rejects any outfit referencing an unknown ID, a wrong slot, a duplicated ID, or a Ghost Element, then re-scores survivors with the existing Pair-Compatibility Scoring Engine (§3.4).
4. Fallback: If the recommendation call fails or validation yields zero outfits, the app falls back to the 4-Stage Execution Flow in §2.1.
5. Visual Generation Canvas: unchanged — same try-on compositing step as §2.1 step 4.

3. Detailed Feature Specifications (V1 Scope)
3.1 Computer Vision Ingestion Pipeline
Background Isolation Service: Automatically isolates clothing boundaries from raw camera snaps or multi-garment photo dumps, dropping complex canvas pixels.

Vision-LLM Tag Generation: Extracted item graphics are processed via a vision model to append structural metadata automatically.

Metadata Field	Data Type / Range	Description / Expected Content Values
slot	Enum	[top, bottom, footwear, outerwear]
formality_score	Float (1.0 - 5.0)	1.0 = Loungewear/Gym; 3.0 = Smart-Casual/Tech-Office; 5.0 = Black Tie
color_profile	Object	Primary hex, secondary hex, categorical classification (e.g., neutral, pastel), and undertone (warm/cool/neutral)
pattern	Enum	[solid, striped, plaid, graphic, textured]
seasonality	Array [Enum]	Any combination of: [summer, spring_fall, winter]
fabric_weight	Enum	[light, medium, heavy]
description	String (≤140 chars)	One concise natural-language sentence describing the garment, used as the recommendation LLM's catalog entry text
style_tags	Array [String]	Free-form style descriptors (e.g., "minimalist", "streetwear") captured at ingestion for recommendation nuance
3.2 Onboarding Experience & Capsule Primer
Empty-State Mitigation Strategy: Users require zero friction during initial setup. A strict item-count onboarding gate is prohibited.

Virtual Capsule Injection: If a slot possesses 0 items, the backend automatically injects default semi-transparent "Ghost Elements" (e.g., standard white tee, tailored black jeans, casual white leather sneakers) into calculations. This populates empty states immediately, transforming a lack of content into an actionable wardrobe feature.

3.3 Intent LLM Prompt Specification
The interpreter must match the following structured output format exactly. Use this template directly within Claude Code system prompt contexts:

JSON
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "StyleConstraints",
  "type": "object",
  "properties": {
    "formality_range": {
      "type": "array",
      "minItems": 2,
      "maxItems": 2,
      "items": { "type": "number", "minimum": 1.0, "maximum": 5.0 }
    },
    "weather_layering_required": { "type": "boolean" },
    "color_palette_vibe": { 
      "type": "array", 
      "items": { "type": "string", "enum": ["neutral", "earth_tones", "monochrome", "vibrant", "pastel"] }
    },
    "season_suitability": { "type": "string", "enum": ["summer", "spring_fall", "winter"] }
  },
  "required": ["formality_range", "weather_layering_required", "color_palette_vibe", "season_suitability"]
}
3.4 Mathematical Pair-Compatibility Scoring Engine
To separate systemic aesthetic alignment from personal body fit preferences, the algorithm breaks scoring evaluations down into separate independent components:

Score 
Total
​
 =P(Pair 
A,B
​
 ∣History)+Preference(Item)
Where pair scoring utilizes a Prior-Adjusted-History calculation framework to avoid data double-counting or initial display confidence skewing:

P(Pair 
A,B
​
 ∣History)= 
w 
0
​
 +N
w 
0
​
 ×Score 
AestheticPrior
​
 +∑Feedback
​
 
Score 
AestheticPrior
​
 : Value between 0 and 1, determined deterministically by hardstyle checks — formality spreads, pattern clashing, and hue/undertone-based color harmony (`Domain/ColorHarmony.swift`: complementary ~180° and analogous <40° hue relationships are rewarded, muddy mid-hue high-saturation clashes are penalized; malformed/missing hex degrades gracefully to the coarser color-vibe category check).

w 
0
​
 : Prior weight constant (recommended default: 3.0 to prevent one extreme user feedback event from breaking system recommendations instantly).

∑Feedback: Sum of historical empirical values (+1.0 for logged likes, -1.0 for logged dislikes).

N: Total count of historical times this pair has been evaluated through the formal feedback interface.

3.5 High-Engagement Feature: "How does it look on me?" Try-On
Target Mechanism: When triggered, the backend pipeline feeds the base portrait photo (secured during onboarding) and the target flatlay item attributes directly into a lightweight context-aware diffusion model or compositing framework.

Rendering Execution: The generated result drapes and dynamically transforms the digital asset structures to accurately map over the user's frame, instantly depicting real-world fit, texture interaction, and color rendering.

3.6 Three-Tier User Feedback Architecture
Feedback collection must execute seamlessly on a single prompt panel every evening or morning-after cycle:

Outfit-Level Event: Metric tracks macroscopic design alignment. Did the overall combination work successfully? [Binary: Yes / No]

Item-Level Assessment: Evaluates decoupled factors like garment fabric comfort, size fitting, or independent confidence metrics. [Thumbs Up / Thumbs Down per piece]

Pair-Level Relational Array: Tracks the core visual chemistry linking items together. Did this specific top combine cleanly with this structural bottom? [Binary: Yes / No]

4. Interface Layout & Screens Breakdown
Developers implementing via Claude Code should follow this standard 4-tab layout wireframe:

Tab 1: Daily Assistant (Core Workspace)
Top element: Natural language input block text area. Example placeholder: "What are you dressing for today?"

Center asset: Swipeable carousel block depicting recommended outfit options formatted as structural flatlays.

Primary interactive button: Callout accent element reading "How does it look on me?" which invokes the visual rendering try-on model instantly on top of the active flatlay selection.

Tab 2: My Closet Inventory Grid
Categorized layout: Segmented into four persistent columns or horizontal tracks: Tops, Bottoms, Footwear, Outerwear.

Display architecture: Displays every background-isolated asset frame seamlessly within clean rounded profile grid slots.

Tab 3: Style Analytics & Feedback Dashboard
Data visualization: Displays highest-ranking individual item pairs, total closet formality balance charting indexes, and an historical calendar tracking successful daily look records.

Tab 4: Combinations
Browsable gallery of every generated try-on image the user has confirmed via "Save this outfit?" (from either Tab 1's "How does it look on me?" or Manual Outfit Pairing). List view with thumbnail, the top/bottom pairing, and save date; tapping a row opens a full-screen, swipeable detail view over the saved set with a delete action.

3.7 Recommendation LLM Spec
The primary recommender (§2.1a). Request and response are both bounded, structured JSON — never free-form image content for the wardrobe side.

Request (constructed locally, sent as prompt + structured user content):
- `prompt`: the user's free text.
- `catalog`: array of compact item entries — `id` (UUID string), `slot`, `formality`, `color_category`, `primary_hex`, `secondary_hex` (nullable), `undertone` (nullable), `pattern`, `seasonality`, `fabric_weight`, `description` (≤140 chars). Ghost Elements excluded. Capped at a configurable `maxItems` (default 150); oversized inventories are deterministically prefiltered (season + formality) and slot-balanced before truncation.
- `profile`: the User Style Profile (§3.8), or omitted if none derived yet.
- `weather`: `{ temperature_fahrenheit, conditions }`, or omitted if unavailable.
- System-prompt guidance includes color-theory rules (complementary/analogous/monochrome pairing, ≤3 color families per outfit, neutral-anchoring) so the LLM's picks are chromatically informed even before local re-scoring.

Response — JSON Schema:
```json
{
  "type": "object",
  "properties": {
    "outfits": {
      "type": "array",
      "maxItems": 5,
      "items": {
        "type": "object",
        "properties": {
          "top_id": { "type": "string" },
          "bottom_id": { "type": "string" },
          "footwear_id": { "type": "string" },
          "outerwear_id": { "type": ["string", "null"] },
          "rationale": { "type": "string" }
        },
        "required": ["top_id", "bottom_id", "footwear_id", "outerwear_id", "rationale"],
        "additionalProperties": false
      }
    }
  },
  "required": ["outfits"],
  "additionalProperties": false
}
```
`temperature: 0` is used to minimize non-determinism. Every returned ID is validated against the catalog before any outfit is shown to the user (§2.1a step 3).

3.8 User Style Profile
Derived once (and re-derivable) from the user's existing onboarding portrait photo via a single vision-LLM call — the only recommendation-adjacent call that sends an image, and it is sent exactly once per derivation, never per recommendation request.

Field	Type	Description
skin_tone	String	Free-text description of the user's skin tone
undertone	Enum	[warm, cool, neutral]
body_type	String	Free-text body-type descriptor used for fit guidance
style_keywords	Array [String]	Inferred style affinities (e.g., "classic", "minimalist")
recommended_colors	Array [String]	Hex or named colors that complement the derived undertone
avoid_colors	Array [String]	Hex or named colors likely to clash with the derived undertone

Stored on-device only (SwiftData, single row). Never logged. Users may opt out via a privacy toggle that forces the fully deterministic §2.1 path and skips the recommendation LLM call entirely (no catalog or profile leaves the device in that mode).

5. Non-Functional, Deployment, & Testing Constraints
Latency Target: The initial text-to-JSON intent constraint calculation must execute within < 400ms. The deterministic local database filtering process must resolve in under 50ms.

State Machine Security: Local scoring evaluation states must persist offline in a SQLite/WatermelonDB storage container to guarantee performance and stability during poor network connectivity.

Agentic Instructions for Claude Code: Implement all functional route definitions cleanly using type-safe validations (Zod/TypeScript). Treat structural style evaluation metrics as unit-testable components utilizing mock datasets to guarantee complete mathematical coverage before applying UI layers.