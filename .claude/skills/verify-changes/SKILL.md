---
name: verify-changes
description: >
  The Readium Swift Toolkit's definition of done. Use this skill BEFORE
  declaring any code change finished, claiming something works, or marking a
  PR as ready. Defines exactly which tests must pass and how to report results
  honestly.
---

# Verify changes

A change is **not done** because it compiles, and not done because it "should work". It is done when the required tests below have been run and pass. Never claim a change works without having run them in this session.

## Required verification

**Always — after any change:** run the tests of every touched package.

```bash
scripts/test.sh ReadiumSharedTests      # Sources/Shared
scripts/test.sh ReadiumStreamerTests    # Sources/Streamer
scripts/test.sh ReadiumNavigatorTests   # Sources/Navigator
scripts/test.sh ReadiumOPDSTests        # Sources/OPDS
scripts/test.sh ReadiumLCPTests         # Sources/LCP
scripts/test.sh ReadiumInternalTests    # Sources/Internal
```

If a change touches `ReadiumShared`, also run the packages that depend on it and were plausibly affected — everything depends on Shared.

**Before declaring a PR ready:** run the full suite.

```bash
scripts/test.sh
```

## Completeness checks

Beyond tests, a change isn't complete until:

- Edits under `Sources/Navigator/EPUB/Scripts/src/` are rebundled with `make scripts` and the regenerated assets are included in the change. (The Stop hook runs this automatically and blocks if bundling fails — fix the errors, don't bypass it.) Verify the TypeScript side directly with `pnpm run lint` in `Sources/Navigator/EPUB/Scripts/` when the JS layer changed.
- Public API changes carry their CHANGELOG.md / Migration Guide entries (see `change-public-api`).
- New targets or dependencies in `Package.swift` are reflected in the generated podspecs (`make podspecs`).

## Report honestly

- If tests fail, say so and show the failing output — never summarize a failure as a success or as "mostly passing".
- If you could not run the tests (missing simulator, tooling, timeout), state that explicitly instead of implying the change is verified.
- Some behavior can't be covered by unit tests (WebView rendering, gestures, UI layout in Navigator). When your change lives there, say plainly which parts are verified by tests and which are unverified, so the reviewer knows what to check manually.
