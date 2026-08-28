//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import Testing
import UIKit

/// aanel: the Rulla (continuous scroll) `.locator` FALLBACK —
/// `EPUBReflowableSpreadView.aanelProgressionFallbackYOffset`, the answer the
/// spread gives once its six text-anchor probes have all missed.
///
/// The bug these cover (device-reproduced 2026-08-25, iPhone 17 Pro): the
/// no-progression case returned a finite `0`. A read-along follow locator
/// carries no `locations` by construction — `readAlong.ts`'s `textOnlyLocator`
/// omits them precisely so Readium's text-anchor search runs at all — so
/// `progression` is nil for EVERY follow, and `0` therefore named the top of
/// the chapter as the destination for any narrated sentence the webview could
/// not resolve. Worse, being finite it also slipped past
/// `ContinuousPaginationView.resolvedTargetYOffset`, which drops only
/// non-finite answers, and so defeated `goToIndex`'s `resolved == nil, …
/// progression == nil` guard — the guard whose own comment says never to
/// synthesize a chapter-start landing from `progression nil → 0`. Measured
/// result: `to == baseOffset`, delta -7337.7pt, 15.7s stranded mid-playback.
///
/// The companion container-level test is
/// `ContinuousPaginationViewTests.unresolvableTextAnchorHoldsPosition`, which
/// pins what the two values actually DO to the reader.
struct EPUBContinuousFallbackTargetTests {
    // The same realistic geometry as EPUBContinuousCentringTests: 4000pt of
    // content between the continuous-mode insets, read in an 800pt viewport.
    private static let documentHeight: CGFloat = 4000
    private static let insetTop: CGFloat = 60
    private static let insetBottom: CGFloat = 60
    private static let viewportHeight: CGFloat = 800

    /// `EPUBReflowableSpreadView.preferredHeight(for:)` in continuous mode.
    private static var pageHeight: CGFloat {
        insetTop + documentHeight + insetBottom
    }

    private static var maxOffset: CGFloat {
        max(pageHeight - viewportHeight, 0)
    }

    /// Defaults to `centred: true` so every pre-r16 case below keeps asserting
    /// exactly what it asserted before — the text-anchor path is unchanged, and
    /// these tests are its record.
    private static func fallback(progression: Double?, centred: Bool = true) -> CGFloat {
        EPUBReflowableSpreadView.aanelProgressionFallbackYOffset(
            progression: progression,
            documentHeight: documentHeight,
            viewportHeight: viewportHeight,
            insetTop: insetTop,
            maxOffset: maxOffset,
            centred: centred
        )
    }

    @Test("an unresolvable locator with NO progression has no destination")
    func noProgressionIsNotANumber() {
        let target = Self.fallback(progression: nil)

        // The regression itself: this returned 0 until r13.
        #expect(target.isNaN)
        #expect(!target.isFinite)
        #expect(target != 0)
    }

    /// The point of NaN rather than any in-range sentinel: `goToIndex` and
    /// `resolvedTargetYOffset` both branch on `isFinite`, and every finite
    /// value — 0 most of all — reads to them as a real destination.
    @Test("the no-destination answer is rejected by the container's finiteness gate")
    func noProgressionFailsTheFinitenessGate() {
        // `resolvedTargetYOffset` keeps an offset only `if offset.isFinite`;
        // `goToIndex` bails with `guard localOffset.isFinite`.
        #expect(!Self.fallback(progression: nil).isFinite)
        // Contrast: the pre-r13 value sails through both.
        #expect(CGFloat(0).isFinite)
    }

    @Test("a locator WITH progression still estimates, centred on the viewport")
    func progressionIsCentred() {
        // Half-way through a 4000pt document, in an 800pt viewport:
        // 60 + (4000 * 0.5 - 400) = 1660.
        #expect(abs(Self.fallback(progression: 0.5) - 1660) < 0.001)
    }

    @Test("a progression at the very start clamps to the top rather than going negative")
    func progressionZeroClampsToZero() {
        // 60 + (0 - 400) = -340, clamped to 0. This lower bound is
        // load-bearing: a TOC target carries `progression: 0`, and an
        // unclamped answer would land in the PREVIOUS resource.
        #expect(Self.fallback(progression: 0) == 0)
    }

    @Test("a progression at the very end clamps to the resource's own maxOffset")
    func progressionOneClampsToMaxOffset() {
        // 60 + (4000 - 400) = 3660, clamped to 4120 - 800 = 3320.
        #expect(Self.fallback(progression: 1) == Self.maxOffset)
    }

    /// The estimate stays a real, finite destination for every progression in
    /// range — only the ABSENCE of one is non-finite. Guards against a future
    /// edit that reaches for NaN too eagerly and kills TOC/search/bookmark
    /// landings, which all carry a progression.
    @Test("every in-range progression yields a finite, in-bounds destination")
    func everyProgressionIsFiniteAndInBounds() {
        for step in 0 ... 20 {
            let progression = Double(step) / 20
            let target = Self.fallback(progression: progression)
            #expect(target.isFinite, "progression \(progression) must estimate")
            #expect(target >= 0, "progression \(progression) went negative")
            #expect(target <= Self.maxOffset, "progression \(progression) overshot")
        }
    }

    // MARK: - r16: what the progression is measured FROM

    /// **A position locator names the viewport TOP.** `FR-RD-11.1` in the app
    /// records `totalProgression` for the top of the view, so centring it on
    /// restore puts the reader half a viewport EARLIER than where they were.
    /// Measured 2026-08-28 as the residual behind a reopen landing short.
    @Test("a position locator lands its progression at the viewport top")
    func positionLocatorIsTopReferenced() {
        let target = Self.fallback(progression: 0.5, centred: false)

        // insetTop + documentHeight * 0.5, no half-viewport subtraction.
        // Tolerance, not `==`: CGFloat, and this file already compares that way
        // at `progressionEstimatesAreCentred` above.
        #expect(abs(target - (Self.insetTop + 2000)) < 0.001)
    }

    /// The paired control. Same progression, same geometry — only the reference
    /// point differs, and it must still differ by exactly half a viewport, or
    /// the case above is asserting the arithmetic rather than the rule.
    @Test("a text anchor that did not resolve is still centred, exactly as before r16")
    func textAnchorStaysCentred() {
        let centred = Self.fallback(progression: 0.5, centred: true)
        let top = Self.fallback(progression: 0.5, centred: false)

        #expect(abs(centred - (Self.insetTop + 2000 - 400)) < 0.001)
        #expect(abs((top - centred) - Self.viewportHeight * 0.5) < 0.001)
    }

    /// The clamp still applies to the top-referenced answer — a progression
    /// near the end must not scroll past the document.
    @Test("a top-referenced target is still clamped to the document")
    func topReferencedTargetIsClamped() {
        #expect(abs(Self.fallback(progression: 1.0, centred: false) - Self.maxOffset) < 0.001)
        #expect(abs(Self.fallback(progression: 0.0, centred: false) - Self.insetTop) < 0.001)
    }

    /// Absence of a destination is unchanged by the reference point: with no
    /// progression there is nowhere to go, whichever way it would be measured.
    @Test("no progression is still no destination, either way")
    func noProgressionIsNaNEitherWay() {
        #expect(Self.fallback(progression: nil, centred: false).isNaN)
        #expect(Self.fallback(progression: nil, centred: true).isNaN)
    }
}
