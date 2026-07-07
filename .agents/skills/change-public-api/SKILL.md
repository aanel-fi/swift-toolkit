---
name: change-public-api
description: >
  Rules for adding, changing, deprecating or removing public API in the Readium
  Swift Toolkit. Use this skill BEFORE adding, changing, or removing any `public`
  declaration in `Sources/`.
---

# Changing the public API

The toolkit is a library. Every `public` symbol is a contract with third-party apps: breaking it breaks their builds. Treat public API changes as the highest-risk edits in this codebase.

## Overview

This toolkit is consumed by third-party apps that compile against it, so every `public` declaration is a commitment. Keep new symbols `internal` unless integrators genuinely need them: making something public later is free; unmaking it costs a deprecation cycle.

## Backward-compatibility policy

Never break a stable public API in one step. Changing or removing a public symbol requires:

1. **Deprecate first**: keep the old signature, mark it deprecated, forward to the replacement:

   ```swift
   @available(*, deprecated, renamed: "coverImage")
   public var cover: UIImage? { coverImage }
   ```

   Use `renamed:` when it's a pure rename (Xcode offers a fix-it), `message:` when the developer must think:

   ```swift
   @available(*, deprecated, message: "Strict URL comparisons can be a source of bug. Use isEquivalentTo() instead.")
   ```

2. **Severity follows major versions**: a deprecation is introduced as a warning (`@available(*, deprecated, ...)`) and is only raised to `@available(*, unavailable, message: ...)` in the **next major version**; unavailable symbols may be removed in the major version after that.
3. **Do not delete or escalate existing shims** as part of an unrelated change; that happens deliberately at major releases.

**Hard (shimless) breaking changes are exceptional.** If a shim isn't feasible (a protocol requirement changed shape, the old behavior can't be emulated), stop and ask the maintainer for explicit approval before proceeding. Never ship a silent break.

## Experimental API

New public API whose shape isn't settled can be hidden behind SPI rather than committed to:

```swift
@_spi(Experimental) public var pointerEvents: [PointerEvent]
```

Consumers must opt in with `@_spi(Experimental) import ReadiumNavigator`, and the symbol carries no stability guarantee. Use this (sparingly, as the existing code does) when you'd otherwise hesitate between `internal` and `public`: promoting an SPI to stable later is free; un-breaking a stable API is not.

## Type and error-handling idioms

- **Fallible async operations return a typed `Result`, not `throws`**:

  ```swift
  func read(range: Range<UInt64>?) async -> ReadResult<Data>   // ReadResult<T> = Result<T, ReadError>
  ```

  Define a dedicated error enum and a `Result` typealias if the domain warrants it. Error types are `public enum … : Error, Sendable` with documented cases and, where useful, an associated `cause` (see `ReadError`, `HTTPError`). Don't throw raw `Error` or `NSError`. No `try!`, no `fatalError()` in library code: a malformed publication must never crash the host app — return an error case, log with `Loggable`, or skip the invalid element.
- **URLs and hrefs**: never pass raw `String` or Foundation `URL` across public APIs for publication resources. Use the toolkit types (`AnyURL`, `RelativeURL`, `AbsoluteURL`/`HTTPURL`/`FileURL`). Compare with `isEquivalentTo()`, not `==`.
- **Media types and formats**: use `MediaType` / `Format`, never string comparison on extensions or MIME strings.
- **Prefer small domain types over primitives** — this codebase wraps concepts (`Locator`, `Language`, `Accessibility`) rather than passing dictionaries and strings.
- **Configurable components** follow the Preferences/Settings pattern used by the navigators (`preferences` in, `settings` out, editors for UI). Don't invent ad-hoc configuration structs for user-adjustable behavior.

## Design conventions

- Public types should be `Sendable` where possible (see the `swift-concurrency` skill).
- Protocol-first for extension points (parsers, resources, HTTP clients), with a `Default…` or format-named implementation.
- Document every public symbol with `///` doc comments, matching the style of surrounding files.
- New code goes in the lowest sensible module (see the module map in `AGENTS.md`); `ReadiumInternal` is for cross-module private helpers, never for public API.

## Cross-toolkit alignment

Public APIs are expected to stay conceptually aligned with the Kotlin toolkit (`readium/kotlin-toolkit`). When designing a new public API, note in the PR description whether an equivalent exists on the Kotlin side and whether the shape matches.

## Required documentation

For every public API change:

1. **Migration Guide** (`docs/Migration Guide.md`): add an entry when integrators must change their code, explaining what they must do to adapt.
2. **Changelog**: document the change using the `update-changelog` skill.
3. **Doc comments**: new public declarations get a `///` comment explaining what the API is for, not how it works.

## Checklist before finishing

- [ ] Old symbols still compile via deprecated shims (or maintainer approved the hard break).
- [ ] New error paths use typed `Result` enums; no `try!`/`fatalError`; nothing can crash the host app.
- [ ] Migration Guide entry added if integrators must act; CHANGELOG.md entry added.
- [ ] Tests cover the new API (see `write-tests`).
