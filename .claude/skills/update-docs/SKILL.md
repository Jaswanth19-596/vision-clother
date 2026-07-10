---
name: update-docs
description: Update project documentation after code changes. Keeps docs in sync with implementation.
user-invocable: true
---

# Update Documentation

After making code changes:
1. Run `git diff HEAD~1 --name-only` to identify changed files.
2. For each changed module, check if the corresponding doc in `docs/` needs updating:
   - Services changed → update `docs/ios/architecture.md`
   - Domain logic changed → update `docs/domain/vision-clother-concepts.md`
   - Conventions violated or new pattern established → update `docs/approach/conventions.md`
3. Update the `CLAUDE.md` in the relevant subdirectory if conventions changed.
4. Report what was updated and why.
