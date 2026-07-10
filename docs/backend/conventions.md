# Backend Conventions — Not Applicable in V1

No backend exists in this codebase yet (see `docs/backend/architecture.md`). CLAUDE.md's Node.js conventions (Zod validation at every border, Vitest/Jest for tests, isolating logic out of controller endpoints) describe how a future proxy backend should be built *if and when one is added* — they are not currently in effect anywhere, since there's no server code to apply them to.

If a `backend/` service is added later (see `docs/backend/architecture.md` § When a backend would become necessary), carry over the conventions already established on the iOS side rather than inventing new ones:

- **Typed schemas at every border** — the iOS client already does this with `Codable` + explicit `CodingKeys` (see `docs/approach/conventions.md`); a Node backend should do the equivalent with Zod schemas mirroring the same wire shapes (`StyleConstraints`, the Fal job submission/status/result payloads).
- **No business logic in the proxy.** The backend's job is exactly "hold the API key and forward the request" — the deterministic scoring engine stays on-device (see `docs/backend/architecture.md` § What NOT to do). A proxy that starts reimplementing scoring or retrieval logic has drifted from the intended architecture.
