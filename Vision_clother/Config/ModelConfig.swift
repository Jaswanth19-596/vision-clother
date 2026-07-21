//
//  ModelConfig.swift
//  Vision_clother
//
//  Single place to pick which OpenRouter model backs each of the three call
//  shapes this app makes. Change a value here and rebuild — no other file
//  needs to change, since every service's `model:` init parameter defaults
//  to one of these three constants (see each service's `init` for which
//  category it belongs to).
//
//  Categories:
//   - textToText:   free-text prompt (+ optional wardrobe catalog / weather)
//                    in, JSON text out. No images sent or received.
//   - imageToText:  one photo in (garment or portrait), structured JSON
//                    text out. Never returns an image.
//   - imageToImage: base portrait + garment reference photos in, a
//                    generated photo out.
//
//  Swap the active value by editing the constant; the commented
//  alternatives below are known-good OpenRouter slugs worth trying.
//
//  Every model constant below (`textToText`, `imageToText`, `imageToImage`,
//  `imageEdit`) is a computed property backed by Firebase Remote Config
//  (`Config/RemoteConfigManager.swift`), so any of them can be hotfixed from
//  the Firebase Console with no rebuild — e.g. if a provider deprecates a
//  model or an image model starts erroring. `textToText` additionally has
//  Remote-Config-backed payload knobs (temperature, max tokens,
//  strict-JSON-schema, a fallback model) that only apply to its own call
//  shape. `Prompts` below stays plain hardcoded literals — prompt text isn't
//  in scope for this hotfix path.
//

import Foundation

enum ModelConfig {
    /// Used by: `OpenRouterOutfitRecommendationService` (primary
    /// LLM-as-Recommender call, CLAUDE.md core invariant),
    /// `OpenRouterIntentExtractionService` (deterministic-fallback
    /// constraint extraction), and `StylistQAService`. All are pure text in,
    /// JSON text out.
    ///
    /// Backed by Firebase Remote Config (`Config/RemoteConfigManager.swift`,
    /// key `ai_primary_model_name`) so the active model can be hotfixed from
    /// the Firebase Console with no app build — `RemoteConfigManager.Defaults`
    /// holds the same literal this constant used to be, and is what every
    /// reader gets offline or before the first fetch.
    static var textToText: String { RemoteConfigManager.shared.primaryModelName }

    /// Emergency-hotfix backup for `textToText` — `OpenRouterOutfitRecommendationService`
    /// retries with this model (Remote Config key `ai_fallback_model_name`)
    /// when the primary model's structured-output attempt comes back
    /// empty/malformed/rejected, so a broken upstream model doesn't need an
    /// app release to route around.
    static var textToTextFallback: String { RemoteConfigManager.shared.fallbackModelName }

    /// `OpenRouterOutfitRecommendationService`'s request temperature (Remote
    /// Config key `ai_temperature`) — `0` minimizes run-to-run
    /// non-determinism on top of the validator's hard guarantees.
    static var temperature: Double { RemoteConfigManager.shared.temperature }

    /// Whether `OpenRouterOutfitRecommendationService`'s structured-output
    /// attempt asks for `strict: true` JSON Schema mode (Remote Config key
    /// `ai_enable_strict_json_schema`) — a hotfix escape hatch for a model
    /// that accepts `response_format: json_schema` but rejects strict mode.
    static var enableStrictJSONSchema: Bool { RemoteConfigManager.shared.enableStrictJSONSchema }

    /// `OpenRouterOutfitRecommendationService`'s `max_tokens` cap (Remote
    /// Config key `ai_max_tokens`).
    static var maxTokens: Int { RemoteConfigManager.shared.maxTokens }

    /// Used by: `OpenRouterVisionMetadataExtractionService` (garment
    /// tagging from one photo) and `OpenRouterUserProfileDerivationService`
    /// (style profile from the onboarding portrait). Both send exactly one
    /// image and return structured JSON text, never an image.
    ///
    /// Remote-Config-backed (key `ai_image_to_text_model_name`) — see the
    /// file header.
    // Alternatives: "google/gemini-3.1-flash-lite", "openai/gpt-5-mini",
    // "qwen/qwen3-vl-30b-a3b-instruct"
    static var imageToText: String { RemoteConfigManager.shared.imageToTextModelName }

    /// Used by: `OpenRouterTryOnRenderService` (virtual try-on render —
    /// base portrait + garment images in, a generated photo out). Nicknamed
    /// "nano banana (lite)" for the underlying Gemini image-generation model.
    ///
    /// Remote-Config-backed (key `ai_image_to_image_model_name`) — see the
    /// file header.
    // Alternatives: "bytedance-seed/seedream-4.5", "google/gemini-2.5-flash-image"
    // (chat-completion image model — see OpenRouterTryOnRenderService's
    // `isChatModel` branch)
    static var imageToImage: String { RemoteConfigManager.shared.imageToImageModelName }

    /// Used by: `OpenRouterBackgroundIsolationService` (AI-assisted
    /// background removal — one garment/upload photo in, an isolated
    /// flatlay product photo out). A different call shape from
    /// `imageToImage` (single reference image + edit prompt, not a
    /// multi-image compose), so it gets its own Remote Config key
    /// (`ai_image_edit_model_name`) even though it currently defaults to the
    /// same model.
    static var imageEdit: String { RemoteConfigManager.shared.imageEditModelName }

    /// OpenRouter only exposes Google's Gemini image-generation models via
    /// the `/chat/completions` endpoint (`modalities: ["text","image"]`) —
    /// unlike Seedream and other dedicated-Images-API models, which use
    /// `/images`. `OpenRouterTryOnRenderService` and
    /// `OpenRouterBackgroundIsolationService` both branch their request
    /// shape on this, so it's centralized here rather than each service
    /// hardcoding its own model-name check (which previously drifted out
    /// of sync when `imageToImage`/`imageEdit` were changed).
    static func isChatCompletionImageModel(_ model: String) -> Bool {
        model.hasPrefix("google/gemini")
    }

    /// Editable prompt text for each LLM call this app makes, alongside the
    /// model constants above — edit a string here and rebuild, no service
    /// file needs to change. Each service still owns its own JSON schema and
    /// the schema-matching instruction appended when structured outputs
    /// aren't used — that's schema plumbing tied to that file's `Codable`
    /// type, not tunable prompt content, so it stays where it is.
    ///
    /// Not covered here: the primary LLM-as-Recommender prompt
    /// (`OutfitRecommendationService`, CLAUDE.md core invariant) is built
    /// dynamically in `Domain/StylistBrain.swift`'s
    /// `DynamicPromptComposer.composeSystemPrompt` — it interleaves static
    /// instructional text with live user-profile/feedback data across
    /// several sequential blocks, so it isn't a single self-contained string
    /// like the ones below and is edited there instead.
    enum Prompts {
        // MARK: Intent extraction (textToText fallback path)

        /// `OpenRouterIntentExtractionService` — deterministic-fallback
        /// constraint extraction from the user's free-text scenario.
        static let intentExtractionSystemPrompt = """
        You extract structured styling constraints from a user's free-text scenario. \
        You do not know what clothing the user owns and must never reference specific \
        garments — only output the constraint fields defined by the schema.
        """

        // MARK: Garment tagging (imageToText)

        /// `OpenRouterVisionMetadataExtractionService` — tags a single
        /// isolated garment photo with structural metadata.
        static let visionMetadataSystemPrompt = """
        You tag a single garment photo with structural metadata for a wardrobe app. \
        The photo shows exactly one clothing item with its background already removed. \
        You do not know what else the user owns and must never reference other garments \
        — only output the metadata fields defined by the schema, based solely on this photo. \
        For "description", write one concise sentence (140 characters or fewer) describing \
        the garment — this text is later shown to a separate recommendation model that never \
        sees the photo, so make it specific (cut, material, notable detail) rather than generic. \
        For "style_tags", give 2-5 short free-form style descriptors (e.g. "minimalist", \
        "streetwear", "tailored"). For "color_profile.undertone", classify the primary color's \
        undertone as "warm", "cool", or "neutral". \
        For "slot", classify which of these seven categories the garment belongs to — use the \
        garment's own cut and construction, not the color or pattern, to decide: \
        "top" = worn on the upper body as a primary layer (t-shirts, shirts, blouses, sweaters, \
        polos, tank tops); \
        "bottom" = worn on the lower body (trousers, pants, jeans, shorts, skirts, chinos, \
        leggings); \
        "footwear" = worn on the feet (sneakers, boots, sandals, heels, loafers, dress shoes); \
        "outerwear" = worn OVER a top as an extra layer, typically with its own front closure \
        (jackets, coats, blazers, cardigans, parkas); \
        "headwear" = worn on the head (hats, caps, beanies, headbands); \
        "accessory" = a single signature accessory piece worn on the body that is not a garment \
        (necklaces and other jewelry, belts, scarves, ties, watches, sunglasses); \
        "bag" = a carried bag (backpacks, totes, handbags, purses, messenger bags). \
        Choose exactly one slot; only choose "outerwear" when the item is clearly meant to be \
        layered over other clothing rather than worn as the primary upper-body garment. Never use \
        "outerwear" as a catch-all for items that don't fit top/bottom/footwear/outerwear — use \
        "headwear", "accessory", or "bag" instead when applicable. \
        Identify the following additional attributes: \
        "garment_subtype": the specific item subtype (e.g. "Oxford Shirt", "Linen Camp Collar Shirt", "Chinos", "Jeans", "Sneakers", "Loafers", "Blazer", "Cardigan"); \
        "fit": the apparent fit/cut (e.g. "Slim", "Oversized", "Regular", "Relaxed", "Tailored"); \
        "silhouette": the silhouette shape (e.g. "Straight", "Boxy", "A-line", "Fitted", "Flared"); \
        "material": the apparent primary material (e.g. "Cotton", "Linen", "Denim", "Wool", "Leather", "Silk", "Knit"); \
        "texture": the tactile surface texture (e.g. "Ribbed", "Smooth", "Coarse", "Knit", "Suede", "Waffle").
        """
        /// User-turn text accompanying the garment photo above.
        static let visionMetadataUserText = "Tag this garment."

        // MARK: Style profile derivation (imageToText)

        /// `OpenRouterUserProfileDerivationService` — derives a styling
        /// profile from the onboarding portrait.
        static let userProfileDerivationSystemPrompt = """
        You analyze a single full-body portrait photo to build a personal styling profile for a \
        wardrobe app. Describe the person's apparent skin tone, undertone (warm/cool/neutral), \
        and general body type in neutral, respectful, non-judgmental language focused only on \
        attributes relevant to color and fit recommendations. Do not identify the person or \
        speculate about anything besides coloring, body type, and style affinities. \
        "recommended_colors" and "avoid_colors" should be a short list of hex codes or common \
        color names that complement or clash with the derived undertone.
        """
        /// User-turn text accompanying the portrait above.
        static let userProfileDerivationUserText = "Build a style profile from this photo."

        // MARK: Try-on render (imageToImage)

        /// `OpenRouterTryOnRenderService`'s chat-completions branch
        /// (Gemini image models) — system role message.
        static let tryOnChatSystemMessage =
            "You are a virtual try-on assistant. Combine the garments in the provided reference images onto the person in the base portrait image, producing a single realistic try-on output image."
        /// `OpenRouterTryOnRenderService`'s chat-completions branch —
        /// instructions text part of the user turn's content array.
        static let tryOnChatInstructions = """
        Apply the garments from the clothing reference images onto the person in the base portrait image. \
        Put the top on their upper body and the bottom on their lower body. If one of the reference images \
        is an outerwear piece (jacket, blazer, coat, cardigan, parka), it must be layered OVER the top as an \
        additional outer garment — both the top and the outerwear must remain visible in the final image \
        (e.g. an open jacket/blazer showing the top underneath, or the top's collar/cuffs visible past the \
        outerwear); never omit the outerwear or substitute it in place of the top. Put footwear on the feet. \
        If a headwear, accessory, or bag reference image is included, render it worn or carried appropriately. \
        Ensure the output is a single realistic photograph of the person wearing every included clothing item, \
        preserving their face, body shape, and background. Output ONLY the resulting generated image.
        """
        /// `OpenRouterTryOnRenderService`'s dedicated-Images-API branch
        /// (e.g. Seedream) — the `"prompt"` field. Worded independently
        /// from `tryOnChatInstructions` above since the two endpoints
        /// expect different prompting styles.
        static let tryOnImagesPrompt = """
                Virtual try-on: the first reference image is a base portrait of a person; every subsequent \
        reference image is one clothing item (top, bottom, footwear, outerwear, headwear, accessory, or bag) \
        to be composed onto that person.
        Put the top on their upper body and the bottom on their lower body. If an outerwear reference image \
        (jacket, blazer, coat, cardigan, parka) is included, layer it OVER the top as an additional outer \
        garment — both the top and the outerwear must remain visible (e.g. an open jacket/blazer showing the \
        top underneath, or the top's collar/cuffs visible past the outerwear); never omit the outerwear or \
        substitute it in place of the top. Put footwear on the feet. If a headwear, accessory, or bag \
        reference image is included, render it worn or carried appropriately.
        Preserve the exact pattern, color, texture, material, stitching, seams, hardware, and logos of every \
        garment. Preserve the person's face, body shape, pose, and background from the base portrait exactly.
        Output a single realistic photograph of the person wearing every included clothing item — natural \
        studio-quality lighting, sharp focus, high resolution. No product-catalog flat lay, no isolated \
        garment renders, no missing body parts, no extra people.
    """

        // MARK: Background isolation / AI removal (imageEdit)

        /// `OpenRouterBackgroundIsolationService`'s chat-completions branch
        /// (Gemini image models) — system role message.
        static let backgroundIsolationChatSystemMessage =
            "You are a product photography assistant. Isolate the garment shown in the reference image into a clean, styled flat-lay product photo, per the instructions."
        /// `OpenRouterBackgroundIsolationService` — shared by both the
        /// chat-completions branch (as the instructions text part) and the
        /// dedicated-Images-API branch (as the `"prompt"` field).
        static let backgroundIsolationFlatlayPrompt = """
        Product photography of the item shown, styled as a clean flat lay, isolated on a transparent background.
        Photograph the item from directly overhead (top-down, 90-degree bird's-eye angle), with no background, backdrop, surface, or shadow — fully isolated with transparent/cutout edges, ready for e-commerce use.
        Arrange the item the way a professional stylist would for a flat lay of this specific product type — symmetrically centered, all parts (sleeves, legs, straps, laces, collar, etc.) laid out naturally and evenly on both sides, with correct proportions and no twisting, overlapping, or awkward angles.
        The fabric surface is taut, smooth, and glass-flat like a freshly ironed garment laid under gentle tension — imagine the fabric pinned flat at the edges so it cannot ripple. Surface reads as crisp and rigid rather than soft or draped, similar to how flat lays are pinned/taped from underneath in professional photography studios. Fabric appears matte and stiff, almost like it's been lightly starched, with no visible give, sag, or fold anywhere on the surface.
        Preserve the exact pattern, color, texture, material, stitching, seams, hardware, logos, and construction details with crisp sharp focus throughout.
        Luxury e-commerce catalog style, even soft lighting across the entire item with no harsh shadows, no gradient, no vignette. Ultra sharp focus, high resolution, professional studio product photography.
        No background, no surface, no table, no bed, no hanger, no mannequin, no human body parts, no shadow, no wrinkles, no creases, no folded/bunched material, no uneven lighting, no cropped edges.
        """
    }
}
