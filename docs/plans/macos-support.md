# macOS Support Implementation Plan

Make the non-UI modules of the Readium Swift Toolkit — ReadiumShared,
ReadiumStreamer, ReadiumOPDS and ReadiumLCP — build, test and work natively
on macOS, alongside the existing iOS/iPadOS support.

## Goals and non-goals

**Goals**

- All products except ReadiumNavigator are fully supported on macOS 14.0+.
- The whole package (including ReadiumNavigator) *compiles* on macOS, so
  `swift build` and `swift test` succeed on both platforms.
- Feature parity across the two official distribution channels (SPM and
  CocoaPods). If third-party pods block macOS on CocoaPods, SPM may ship
  first and the pods follow (see risks).
- A new `Bitmap` type replaces `UIImage` as the image currency of the public
  API.
- The existing SwiftUI `LCPDialog` works on macOS.
- A minimal macOS Playground target validates the toolkit end-to-end.

**Non-goals (future phases)**

- Porting the Navigators (EPUB, PDF, audio) to macOS. The Navigator module
  compiles empty on macOS; a native macOS reading UI is a separate plan.
- Mac Catalyst and visionOS support.
- Porting the TestApp to macOS.

## Decisions

| Decision | Choice |
|---|---|
| Navigator scope | Out of this plan; compiles empty on macOS via `#if os(iOS)` |
| macOS deployment target | 14.0 |
| Image API currency | New `Bitmap` struct in ReadiumShared, CGImage-backed |
| SVG covers | The private CoreSVG shim moves into the `Bitmap` decoding path, rendered via plain `CGContext`; macOS symbol availability verified by a spike before committing |
| Phase ordering | `Bitmap` lands first, while the package is still iOS-only, so the macOS build flip only needs guards on genuinely iOS-only files — no throwaway guards on image code or tests |
| `AudioSession` | iOS-only, compiled out on macOS |
| `NowPlayingInfo` | Cross-platform (MPNowPlayingInfoCenter exists on macOS, with macOS-specific additions: `playbackState`, `NSImage`-based artwork) |
| LCP passphrase dialog | Existing SwiftUI `LCPDialog` ported to macOS; UIKit `LCPDialogViewController` stays iOS-only, not deprecated |
| `LCPRenewDelegate` | Protocol split into its own platform-neutral file; UIKit default stays iOS-only; macOS default opens the renewal URL in the browser |
| API breakage | Hard break, folded into the current `[Unreleased: swift6]` train, with migration guide entries |
| Distribution | SPM and CocoaPods both declare macOS; includes republishing the Readium fork pods with macOS support |
| Testing | `swift test` natively on macOS in CI, in addition to the existing iOS Simulator run |
| Validation app | Minimal macOS Playground target |

See `CONTEXT.md` for the canonical definitions of *Bitmap*, *Audio Session*
and *Now Playing Info*.

## Phase 0 — CoreSVG spike

`ResourceCoverService` renders SVG covers through `UIImage.fromSVG`, which
relies on the private CoreSVG API (`CGSVGDocumentCreateFromData`,
`CGContextDrawSVGDocument`, …) loaded via `dlsym`. Before Phase 1 commits to
the `Bitmap` design, verify on macOS 14 that:

- the CoreSVG symbols resolve at runtime;
- rendering an SVG document into a plain `CGContext` (replacing
  `UIGraphicsImageRenderer`) produces correct output on both platforms.

If the symbols are unavailable or broken on macOS, decide explicitly between
dropping SVG cover support on macOS (documented in the migration guide) or an
alternative rendering path — do not let the feature disappear silently.

## Phase 1 — The `Bitmap` type

Introduce `Bitmap` in ReadiumShared and remove `UIImage` from all public
APIs. This is the breaking change of the plan. It lands while the package is
still iOS-only: purely additive from a platform standpoint, independently
testable on iOS, and it clears the image code out of the way of the macOS
build flip (Phase 2).

1. New `Sources/Shared/Toolkit/Bitmap.swift`:
   - Immutable struct wrapping a `CGImage`; `Sendable`.
   - `size: CGSize` (in pixels — `Bitmap` has no point/scale semantics),
     `cgImage: CGImage`.
   - Decoding initializer from `Data` (via ImageIO / `CGImageSource`).
   - SVG decoding path ported from `UIImage.fromSVG`, using the CoreSVG shim
     validated in Phase 0 and rendering into a `CGContext` instead of
     `UIGraphicsImageRenderer`, so it works on both platforms.
   - Scaling helper replacing the `UIGraphicsImageRenderer`-based
     `Sources/Shared/Toolkit/Extensions/UIImage.swift` extensions, using
     `CGContext` so it works on both platforms.
   - Platform conveniences: `uiImage` (iOS), `nsImage` (macOS), and
     initializers from `UIImage`/`NSImage`.
2. Migrate API surfaces from `UIImage` to `Bitmap`:
   - `CoverService` (`cover()`, `coverFitting(maxSize:)`) and its
     implementations `GeneratedCoverService`, `ResourceCoverService`, and
     `Publication.cover`.
   - `PDFDocument.cover()` and its implementations in `CGPDF.swift` and
     `PDFKit.swift` (also replace `UIColor.white.cgColor` with a Core
     Graphics color).
   - `NowPlayingInfo.MediaInfo.artwork`.
   - `HTTPClient.fetchImage(_:)` — drop the `#if canImport(UIKit)` guard.
   - `AudioPublicationManifestAugmentor` (ReadiumStreamer) — cover extraction
     from AVFoundation metadata decodes to `Bitmap`.
3. Delete `Sources/Shared/Toolkit/Extensions/UIImage.swift` (its SVG and
   scaling logic now lives in `Bitmap`).
4. Migrate the test suite off `UIImage` so it is platform-neutral:
   - `Tests/SharedTests/Asserts.swift` (`AssertImageEqual`) compares
     `Bitmap`s.
   - `Tests/SharedTests/Toolkit/Extensions/UIImageTests.swift` becomes
     `BitmapTests` (decode, SVG, scale, fitting).
   - The cover service tests (`CoverServiceTests`,
     `GeneratedCoverServiceTests`, `ResourceCoverServiceTests`) use `Bitmap`.
5. Changelog + migration guide entry, including the one-line fixes
   (`UIImage(cgImage: bitmap.cgImage)`, `bitmap.uiImage`) and the size
   semantics change: `Bitmap.size` and `coverFitting(maxSize:)` are expressed
   in pixels, whereas `UIImage.size` was in points with a separate `scale`.

## Phase 2 — Build groundwork

Everything compiles for macOS; no behavior change on iOS. With Phase 1 done,
the remaining macOS build blockers are the genuinely iOS-only files below —
no temporary guards on image code or tests are needed.

1. `Package.swift`
   - Add `.macOS("14.0")` to `platforms`.
   - Condition the ReadiumShared linker settings:
     `.linkedFramework("UIKit", .when(platforms: [.iOS]))`.
2. Guard ReadiumNavigator wholesale: wrap every source file in
   `#if os(iOS)` (a scripted mechanical pass). Platform-neutral files
   (preferences types, locator logic) can be un-guarded opportunistically in
   the future Navigator plan.
3. Guard the iOS-only files in ReadiumShared and ReadiumLCP. The complete
   list, with each file's fate:
   - `Sources/Shared/Toolkit/Media/AudioSession.swift` (and its `Observer`
     machinery) — permanently iOS-only (Phase 3).
   - `Sources/Shared/Toolkit/Media/NowPlayingInfo.swift` — temporarily
     guarded; ported to macOS in Phase 3.
   - `Sources/LCP/Authentications/LCPDialogViewController.swift`,
     `LCPDialogAuthentication.swift` — permanently iOS-only (Phase 4).
   - `Sources/LCP/Authentications/LCPDialog.swift` — temporarily guarded; it
     does not compile on macOS today (`UIApplication.shared.open`,
     `.textInputAutocapitalization`, `.navigationViewStyle(.stack)`). Ported
     in Phase 4.
   - `Sources/LCP/LCPRenewDelegate.swift` — cannot be guarded wholesale: it
     mixes the platform-neutral `LCPRenewDelegate` protocol with the
     UIKit/SafariServices-based `LCPDefaultRenewDelegate`, with `import
     UIKit` / `import SafariServices` at file scope. Split it now: the
     protocol moves to its own platform-neutral file; the default
     implementation stays behind `#if os(iOS)`. The macOS default arrives in
     Phase 4.
   - ReadiumStreamer, ReadiumOPDS and ReadiumInternal have no iOS-only files
     left after Phase 1.
4. Verify third-party SPM dependencies build for macOS 14 (CryptoSwift, Zip,
   Fuzi, ZIPFoundation, SwiftSoup all declare macOS support; DifferenceKit
   still builds for macOS but its code is only used behind the Navigator
   guards).
5. CocoaPods — note the pods use a *different* dependency set than SPM:
   - Add `osx.deployment_target = '14.0'` to every podspec in
     `Support/CocoaPods` except `ReadiumNavigator.podspec`.
   - `ReadiumShared.podspec` depends on `Minizip` (not `Zip`); verify the
     published `Minizip` pod supports macOS.
   - The Readium fork pods (`ReadiumFuzi`, `ReadiumZIPFoundation`) must
     declare `osx.deployment_target` in their *published* podspecs and be
     republished — a cross-repo prerequisite, since `pod lib lint` fails if
     any transitive pod lacks the platform.
   - Validate with `pod lib lint` including the macOS platform.

Exit criterion: `swift build` and `swift test` pass natively on macOS with
only the guards listed above.

## Phase 3 — Media APIs

1. `AudioSession` (and its `Observer` machinery) stays permanently
   `#if os(iOS)`: the concept has no macOS equivalent.
2. `NowPlayingInfo` becomes cross-platform. This is more than recompilation;
   macOS needs specific additions:
   - `MPMediaItemArtwork`'s request handler traffics in `UIImage` on iOS and
     `NSImage` on macOS — bridge from `Bitmap` per platform (Phase 1
     conveniences).
   - On macOS the now-playing item only surfaces in the system media
     controls when the app sets `MPNowPlayingInfoCenter.playbackState` (a
     macOS-only property) and registers remote command handlers — expose
     what the toolkit must, document what remains the app's concern.
   - Verify the menu-bar/Control Center integration from the macOS
     Playground (Phase 6).

## Phase 4 — ReadiumLCP

1. `LCPDialog` (SwiftUI) compiles and works on macOS — the known compile
   blockers, then a layout pass:
   - Replace `UIApplication.shared.open(url.url)` with the SwiftUI `openURL`
     environment action (works on both platforms).
   - `.textInputAutocapitalization(.never)` is unavailable on macOS — guard
     it (`#if os(iOS)` view modifier or conditional extension).
   - `.navigationViewStyle(.stack)` is unavailable on macOS — apply it
     conditionally.
   - Audit layout for macOS presentation (sheet sizing, keyboard focus).
2. `LCPDialogViewController` and `LCPDialogAuthentication` stay iOS-only
   (`#if os(iOS)`), and are *not* deprecated.
3. `LCPRenewDelegate` (file already split in Phase 2):
   - The protocol stays platform-neutral.
   - The existing UIKit-presenting default implementation stays iOS-only.
   - Add a macOS default that opens the renewal URL in the default browser
     (`NSWorkspace.shared.open`).
4. Documentation: `LCPService.init(deviceName:)` docs recommend
   `UIDevice.current.name`; add the macOS equivalent
   (e.g. `Host.current().localizedName`).

## Phase 5 — Testing and CI

1. `scripts/test.sh`: add a macOS run (`swift test`, optionally filtered),
   alongside the existing iOS Simulator TestApp run.
2. `.github/workflows/checks.yml`: add a macOS job (or destination) that runs
   `swift build` + `swift test` for the package natively.
3. Audit remaining test fixtures/tests for iOS assumptions. The image tests
   were migrated in Phase 1; this pass catches anything else (e.g. implicit
   reliance on a UIKit host app or iOS-specific paths).

## Phase 6 — macOS Playground target

A minimal macOS app target in `Playground/` that exercises what unit tests
cannot:

- Open an EPUB/PDF/audiobook from disk (validates sandboxed, security-scoped
  file access with the streamer).
- Display the publication cover, including an SVG cover (validates `Bitmap`
  and the CoreSVG path end-to-end).
- Open an LCP-protected publication and trigger `LCPDialog` (requires the
  app to provide a macOS build of `liblcp`; the toolkit itself has no binary
  dependency thanks to the `LCPClient` injection point).
- Play an audiobook chapter and verify `NowPlayingInfo` in the system media
  controls (including the `playbackState` requirement from Phase 3).

## Phase 7 — Documentation and release

1. Migration guide: `Bitmap` breakage — including the pixels-vs-points size
   semantics (Phase 1) — and LCP macOS notes.
2. `CHANGELOG.md`: entries under the current unreleased train.
3. README: platform support matrix (iOS 15+, macOS 14+; Navigator iOS-only
   for now).
4. Note in `docs/Readium.md` / guides where platform availability differs
   (`AudioSession`, LCP UIKit dialog, Navigator).

## Risks and watch items

- **CoreSVG private API**: SVG cover rendering depends on private CoreSVG
  symbols resolved via `dlsym`. Phase 0 verifies them on macOS, but they can
  vanish in any OS release on either platform; the `Bitmap` SVG path must
  keep degrading gracefully (return `nil`, never crash).
- **App sandbox**: macOS apps are sandboxed differently from iOS; file
  access through user-selected files and security-scoped bookmarks is the
  adopting app's concern, but the Playground target should prove the
  streamer works under sandboxing.
- **liblcp on macOS**: the toolkit is clean, but real-world LCP adoption
  depends on EDRLab shipping a macOS `liblcp`. Worth confirming availability
  before announcing LCP-on-macOS support.
- **CocoaPods ecosystem**: macOS feature parity on CocoaPods is gated on
  third parties — the `Minizip` pod's macOS support and republishing the
  `ReadiumFuzi`/`ReadiumZIPFoundation` podspecs. If a pod blocks, decide
  whether CocoaPods macOS support ships later than SPM rather than holding
  the release.
- **`swift test` vs TestApp test plan**: the package tests must not silently
  depend on a UIKit host app; running them via `swift test` on macOS will
  surface any such dependency early (do this at the start of Phase 2).
- **NSImage non-Sendability**: keep `NSImage` strictly at the convenience
  boundary of `Bitmap`; never store it.
