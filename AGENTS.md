# AGENTS.md

The Readium Swift toolkit is used to develop reading apps for iOS, with support for EPUB, PDF, audiobooks and comics. It is a **library consumed by third-party apps**: its public API is a contract, and quality expectations are high.

`CONTEXT.md` defines the project's domain language (Publication, Manifest, Locator, Resource, Container, Asset…) — use those terms, and their listed alternatives to avoid, in code and documentation.

## Modules

Each module under `Sources/` is a separate package with its own test target under `Tests/`.

| Module | Package | Responsibility |
|---|---|---|
| `Sources/Shared` | `ReadiumShared` | Core models (`Publication`, `Link`, `Locator`), toolkit (URLs, HTTP, data/resources, formats). Everything else depends on it. |
| `Sources/Streamer` | `ReadiumStreamer` | Parsing publications (EPUB, PDF, audiobook, comics) into `Publication` objects. |
| `Sources/Navigator` | `ReadiumNavigator` | Rendering and navigating publications (UIKit/WebView-based). UI-facing code lives here. |
| `Sources/OPDS` | `ReadiumOPDS` | OPDS catalog feed parsing. |
| `Sources/LCP` | `ReadiumLCP` | Readium LCP DRM support. |
| `Sources/Internal` | `ReadiumInternal` | Private helpers shared across modules. Not public API. |
| `Sources/Adapters` | `ReadiumAdapters` | Bridges to third-party dependencies (e.g. GCDWebServer, PDF engines). |

Put new code in the lowest layer that needs it — never add UI concerns to Shared/Streamer, never parse publications in Navigator.

## Commands

- `scripts/test.sh` — run all tests
- `scripts/test.sh ReadiumSharedTests` — run tests for one package (`ReadiumSharedTests`, `ReadiumStreamerTests`, `ReadiumNavigatorTests`, `ReadiumOPDSTests`, `ReadiumLCPTests`, `ReadiumInternalTests`)
- `make format` — format sources with SwiftFormat
- `make scripts` — rebundle the EPUB navigator JavaScript after editing `Sources/Navigator/EPUB/Scripts/src/`

## Policies

### Discuss new features first

Before implementing a **new feature**, warn the user: the Readium project asks that new features be discussed first in a GitHub issue or discussion at <https://github.com/readium/swift-toolkit>, and undiscussed feature changes may be refused. Ask the user to confirm they want to proceed anyway. This does not apply to bug fixes or small changes such as typos.

### Public API is a contract

Changing or removing a public symbol requires a deprecated compatibility shim whenever feasible, a `CHANGELOG.md` entry, and a `docs/Migration Guide.md` entry when integrators must change their code. Hard (shimless) breaking changes require explicit maintainer approval — never ship them silently. See the `change-public-api` skill before touching any public API.

### Verification

A change is not done until the tests of every touched package pass (`scripts/test.sh <Package>Tests`), and the full suite passes before a PR is ready. See the `verify-changes` skill.

## Skill routing

Consult the matching skill **before** starting these tasks — not after:

| When you are about to… | Use skill |
|---|---|
| Add, change, or remove any `public` declaration | `change-public-api` |
| Fix a concurrency compiler error, add `Sendable`/`@MainActor`/locks, or write async code | `swift-concurrency` |
| Declare a task finished or a PR ready | `verify-changes` |
| Write or modify tests | `write-tests` |
| Document a change for integrators | `update-changelog` |
| Write a user guide under `docs/Guides/` | `write-guide` |

## More documentation

- `CONTEXT.md` — domain language and core concepts
- `CONTRIBUTING.md` — coding standard, EPUB navigator JavaScript layer details
- `MAINTAINING.md` — release process
- `docs/Guides/` — user-facing guides for app developers
- `docs/Migration Guide.md` — how integrators adapt to breaking changes
