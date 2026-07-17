# Services (Features Layer)

Feature-level service wiring, not to be confused with the root `Services/` layer.
- **ServiceFactory:** Decides mock vs real implementations. In production, it returns auth-gated wrappers (`AuthGated*Service`) that re-check `AuthService.shared.isSignedIn` on every call, avoiding the stale construction-time snapshot issue.
- **Try-On Rendering:** `OpenRouterTryOnRenderService` drives a single synchronous Gemini image-to-image request via OpenRouter's `/chat/completions` endpoint with a 120s bounded timeout. No async polling loops, Fal pipelines, or FASHN dependencies are used.
- Tests and `#Preview` always get mock implementations — no real auth/network required.
- See root `Services/CLAUDE.md` for the protocol-first pattern and provider details.
