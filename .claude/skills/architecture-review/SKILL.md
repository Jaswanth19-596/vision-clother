---
name: architecture-review
description: Review changes against the project architecture and coding conventions.
user-invocable: true
---

# Architecture Review

Before reviewing, read these files:
- `docs/ios/architecture.md`
- `docs/approach/conventions.md`
- `docs/domain/vision-clother-concepts.md`

Then review the most recent changes (use `git diff HEAD~1`) against:
1. Does the change respect the LLM-as-extractor invariant? (LLM never sees wardrobe inventory)
2. Are Codable types using explicit CodingKeys?
3. Is async/await used correctly (no bare unbounded loops)?
4. Are new protocols tested with mocks?

Report violations with file:line references.
