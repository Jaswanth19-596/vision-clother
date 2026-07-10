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

⚠️ Architecture Rule: Never pass the entire wardrobe catalog into the LLM context window. Use the LLM exclusively as a Structured Constraint Interpreter to construct an efficient deterministic local query.

2.1 The 4-Stage Execution Flow
Intent Extraction Layer (LLM API): User passes fuzzy text ("Tech interview at Morgan Stanley") along with localized weather parameters. The LLM translates this text into a strict JSON payload containing constraint fields (formality range, seasonal tags, color palettes).

Candidate Retrieval Layer (Local Database Query): The local system converts the JSON criteria into SQL/NoSQL parameters, retrieving all valid inventory candidates isolated by structural slot (Tops, Bottoms, Footwear, Outerwear).

Permutation & Heuristic Engine (Deterministic Backend Code): Local code computes the cross-product combinations of matching clothes and evaluates them using absolute stylistic priors (color count ceilings, formality delta constraints, and pattern clashing logic).

Visual Generation Canvas (Image Generation Pipeline): The top-performing flatlay options are presented to the user. Upon tapping "How does it look on me?", the pipeline composites the chosen clothing layer over the user's base onboarding image to deliver a tailored, context-aware visual preview.

3. Detailed Feature Specifications (V1 Scope)
3.1 Computer Vision Ingestion Pipeline
Background Isolation Service: Automatically isolates clothing boundaries from raw camera snaps or multi-garment photo dumps, dropping complex canvas pixels.

Vision-LLM Tag Generation: Extracted item graphics are processed via a vision model to append structural metadata automatically.

Metadata Field	Data Type / Range	Description / Expected Content Values
slot	Enum	[top, bottom, footwear, outerwear]
formality_score	Float (1.0 - 5.0)	1.0 = Loungewear/Gym; 3.0 = Smart-Casual/Tech-Office; 5.0 = Black Tie
color_profile	Object	Primary hex, secondary hex, and categorical classification (e.g., neutral, pastel)
pattern	Enum	[solid, striped, plaid, graphic, textured]
seasonality	Array [Enum]	Any combination of: [summer, spring_fall, winter]
fabric_weight	Enum	[light, medium, heavy]
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
 : Value between 0 and 1, determined deterministically by hardstyle checks (color combinations, formality spreads).

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

5. Non-Functional, Deployment, & Testing Constraints
Latency Target: The initial text-to-JSON intent constraint calculation must execute within < 400ms. The deterministic local database filtering process must resolve in under 50ms.

State Machine Security: Local scoring evaluation states must persist offline in a SQLite/WatermelonDB storage container to guarantee performance and stability during poor network connectivity.

Agentic Instructions for Claude Code: Implement all functional route definitions cleanly using type-safe validations (Zod/TypeScript). Treat structural style evaluation metrics as unit-testable components utilizing mock datasets to guarantee complete mathematical coverage before applying UI layers.