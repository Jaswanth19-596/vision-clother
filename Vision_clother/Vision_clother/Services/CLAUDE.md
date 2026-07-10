# Services (Features Layer)

Feature-level service wiring, not to be confused with the root `Services/` layer.
- `ServiceFactory` decides mock vs real implementations based on API key availability.
- `OpenRouterTryOnRenderService` handles the try-on render pipeline at the feature level.
- Tests and `#Preview` always get mock implementations — no real API key required.
- See root `Services/CLAUDE.md` for the protocol-first pattern and provider details.
