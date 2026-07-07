---
name: swift-concurrency
description: >
  The Readium Swift Toolkit's Swift 6 strict-concurrency rules. Use this skill
  BEFORE fixing a concurrency compiler error, adding Sendable/@MainActor/locks,
  writing async code, or whenever tempted by @unchecked Sendable,
  nonisolated(unsafe), or Task { } as a quick fix.
---

# Swift Concurrency Rules

The toolkit builds with Swift 6 strict concurrency. The compiler catches data races — but it happily accepts *bad fixes*. These rules exist so a concurrency error is resolved by design, not by silencing.

When the compiler reports an isolation or Sendable error, the answer is almost always one of, in order of preference:

1. Make the type genuinely `Sendable` (value type, `let` properties).
2. Protect the mutable state with `Mutex` from ReadiumShared.
3. Isolate to an actor or `@MainActor` **only if** the type belongs there (see rules 3 and 6).

Never the escape hatches (`@unchecked`, `nonisolated(unsafe)`, fire-and-forget `Task`).

## Rule 1 — `@unchecked Sendable` requires a written justification

`@unchecked Sendable` is a promise to the compiler that *you* uphold thread safety. Using it to silence an error ships a data race.

If you must use it, the conformance needs a comment naming the invariant that protects the state (which lock, or why the state is immutable in practice). If you can't write that sentence, the conformance is wrong — use `Mutex` instead.

```swift
// WRONG — silences the compiler, protects nothing:
final class Cache: @unchecked Sendable {
    var entries: [String: Data] = [:]
}

// RIGHT — the Mutex makes it genuinely Sendable:
final class Cache: Sendable {
    private let entries = Mutex<[String: Data]>([:])
}
```

## Rule 2 — Prefer genuine Sendability

Before adding any annotation, try making the type actually safe: convert classes to structs where identity isn't needed, make properties `let`, inject dependencies as `Sendable` values. Most model types in `ReadiumShared` are `Sendable` structs — follow that pattern.

## Rule 3 — `@MainActor` is for UI-facing types only

Navigators, view controllers, and delegates that touch UIKit are `@MainActor`. Model and toolkit types in Shared/Streamer/OPDS/LCP are **not** — annotating them `@MainActor` to fix an error moves library work onto the main thread and poisons every caller.

## Rule 4 — async/await only; no new GCD or completion handlers

Migrated modules use structured concurrency. Don't introduce `DispatchQueue`, semaphores, or completion-handler APIs. Fallible async operations return typed `Result`s (`async -> ReadResult<T>`), per the `change-public-api` skill.

## Rule 5 — No fire-and-forget `Task { }` to dodge isolation errors

Wrapping a call in `Task { }` to make an error disappear changes ordering: the work now runs *sometime later*, races with subsequent code, and errors vanish. Use `Task` only when detaching is the actual design intent, and handle its failure. If you need a value, `await` it in the existing async context instead.

## Rule 6 — Locks vs. actors: default to `Mutex`

To protect shared mutable state inside an otherwise-synchronous type, use `Mutex` from ReadiumShared (`Sources/Shared/Toolkit/Mutex.swift`) — a drop-in for `Synchronization.Mutex` that works on iOS 15+:

```swift
final class Manager: Sendable {
    private let cache = Mutex<[String: Int]>([:])

    func save(_ value: Int, for key: String) {
        cache.withLock { $0[key] = value }
    }
}
```

Do **not** convert a type to an actor just to protect its state: an actor forces `await` on every caller and contaminates the public API with async. Reserve actors for types whose work is already inherently async (network, I/O pipelines) or whose critical sections are long.

`withLock` takes a synchronous closure — you cannot hold the lock across an `await`. That is a feature; never restructure code to smuggle async work inside a critical section.

## Rule 7 — `nonisolated(unsafe)` is banned in ordinary code

If mutable state needs cross-thread access, wrap it in `Mutex`. The only legitimate home for `nonisolated(unsafe)` is inside a low-level synchronization primitive (like `Mutex` itself), where a documented invariant does the protection. Reaching for it anywhere else means the design is wrong — the fix is `Mutex`, `let`, or actor isolation.
