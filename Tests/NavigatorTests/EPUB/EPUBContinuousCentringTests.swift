//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import Testing
import UIKit

/// aanel: the Rulla (continuous scroll) read-along centring arithmetic —
/// `EPUBReflowableSpreadView.aanelCentredYOffset`.
///
/// The bug these cover: the anchor-resolved target used to be clamped to the
/// CURRENT resource's own `pageHeight - viewportHeight`. Once the narrated
/// sentence entered the last half-viewport of a chapter, every following
/// sentence resolved to that same clamped value, `goToIndex`'s
/// `abs(contentOffset.y - targetY) <= 2` convergence check broke immediately
/// and reported success without moving, and the highlight rode to the bottom
/// of the screen for the last half-viewport of EVERY chapter.
struct EPUBContinuousCentringTests {
    // A chapter with a realistic geometry: 4000pt of content between the
    // continuous-mode insets, read in an 800pt viewport.
    private static let documentHeight: CGFloat = 4000
    private static let insetTop: CGFloat = 60
    private static let insetBottom: CGFloat = 60
    private static let viewportHeight: CGFloat = 800

    /// `EPUBReflowableSpreadView.preferredHeight(for:)` in continuous mode.
    private static var pageHeight: CGFloat {
        insetTop + documentHeight + insetBottom
    }

    /// The bound the `.locator` branch used to be clamped to, and that
    /// `case .end` still returns.
    private static var maxOffset: CGFloat {
        max(pageHeight - viewportHeight, 0)
    }

    private static func target(
        rectTop: CGFloat,
        rectHeight: CGFloat = 40,
        mayEnterPreviousResource: Bool = true
    ) -> CGFloat {
        EPUBReflowableSpreadView.aanelCentredYOffset(
            rectTop: rectTop,
            rectHeight: rectHeight,
            viewportHeight: viewportHeight,
            insetTop: insetTop,
            mayEnterPreviousResource: mayEnterPreviousResource
        )
    }

    /// The geometry the head-of-chapter defect actually happens in: an
    /// INTERIOR resource, where `aanelContinuousInsets` zeroes both insets.
    private static func interiorTarget(
        rectTop: CGFloat,
        rectHeight: CGFloat = 40,
        mayEnterPreviousResource: Bool = true
    ) -> CGFloat {
        EPUBReflowableSpreadView.aanelCentredYOffset(
            rectTop: rectTop,
            rectHeight: rectHeight,
            viewportHeight: viewportHeight,
            insetTop: 0,
            mayEnterPreviousResource: mayEnterPreviousResource
        )
    }

    @Test("a sentence mid-chapter is centred on its visible mass")
    func midChapterSentenceIsCentred() {
        // visibleMass = min(40, 400) = 40
        // centred = 2000 + 20 - 400 = 1620, plus the 60pt top inset
        #expect(Self.target(rectTop: 2000) == 1680)
    }

    @Test("a sentence taller than half the viewport centres only its visible mass")
    func tallSentenceCentresItsVisibleMass() {
        // visibleMass is capped at viewportHeight / 2 = 400, so a 5000pt
        // sentence is treated as 400pt of mass: 2000 + 200 - 400 + 60.
        #expect(Self.target(rectTop: 2000, rectHeight: 5000) == 1860)
    }

    /// The regression. Two consecutive sentences inside the last half-viewport
    /// of the chapter must still produce DISTINCT, increasing targets past the
    /// resource's own end — that is what scrolls the seam up and keeps the
    /// sentence centred instead of letting it ride to the bottom.
    @Test("consecutive sentences in the last half-viewport keep advancing past the resource's end")
    func lastHalfViewportKeepsAdvancing() {
        // The last half-viewport of the document starts here.
        let tailStart = Self.documentHeight - Self.viewportHeight / 2
        #expect(tailStart == 3600)

        let first = Self.target(rectTop: 3700)
        let second = Self.target(rectTop: 3800)
        let third = Self.target(rectTop: Self.documentHeight)

        // Each sentence resolves somewhere new — the convergence check in
        // `goToIndex` therefore keeps moving the surface.
        #expect(first < second)
        #expect(second < third)
        #expect(second - first == 100)

        // And all three are past the bound the old clamp imposed. Under that
        // clamp all three collapsed to `maxOffset` and the surface froze.
        #expect(first > Self.maxOffset)
        #expect(second > Self.maxOffset)
        #expect(third > Self.maxOffset)
    }

    /// The lower bound is load-bearing for a locator that names a PLACE rather
    /// than a piece of narrated text: a TOC target resolves its fragment at the
    /// very top of the resource and would otherwise compute `-viewportHeight / 2`,
    /// landing back inside the PREVIOUS resource — the reader taps a chapter
    /// and gets the end of the previous one.
    ///
    /// This is the PAIRED CONTROL for the read-along tests below: same inputs,
    /// `mayEnterPreviousResource` flipped, and the answer must still be floored.
    @Test("a fragment-resolved target at the top of the resource is floored at zero")
    func topOfResourceIsFlooredAtZero() {
        #expect(Self.target(rectTop: 0, rectHeight: 0, mayEnterPreviousResource: false) == 0)
        #expect(Self.target(rectTop: 0, mayEnterPreviousResource: false) == 0)
        // Unfloored this would be 60 + 0 + 20 - 400 = -320.
        #expect(Self.target(rectTop: 100, mayEnterPreviousResource: false) == 0)

        // …and on an interior resource, where the top inset is zero and so
        // cannot do the flooring by itself.
        #expect(Self.interiorTarget(rectTop: 0, mayEnterPreviousResource: false) == 0)
        #expect(Self.interiorTarget(rectTop: 100, mayEnterPreviousResource: false) == 0)
        #expect(Self.interiorTarget(rectTop: 379, mayEnterPreviousResource: false) == 0)
    }

    // MARK: - r18: the head of the chapter, the mirror of the r11 tail defect

    /// **The defect.** For an INTERIOR chapter `aanelContinuousInsets.top` is 0,
    /// so the floor bit whenever `rectTop + visibleMass / 2 < viewportHeight / 2`
    /// — the first ~half viewport of EVERY chapter mapped to the same target, 0.
    /// A cross-chapter read-along follow targets exactly that band by
    /// construction, because narration has just entered the resource:
    /// `goToIndex`'s `abs(contentOffset.y - targetY) <= 2` convergence check
    /// then reported success without moving and the highlight walked down a
    /// stationary page until the floor stopped binding (device-observed
    /// 2026-08-31, physical iPad: "after chapter boundary the top sentences are
    /// highlighted and page stays put until active sentence reaches center
    /// screen, then playback & scroll continue normally").
    ///
    /// Exactly the r11 tail defect, at the other end of the chapter.
    @Test("consecutive sentences in the first half-viewport keep advancing instead of collapsing to the chapter top")
    func firstHalfViewportKeepsAdvancing() {
        // With a 40pt sentence the floor binds for every rectTop below 380.
        #expect(Self.interiorTarget(rectTop: 380) == 0)

        let first = Self.interiorTarget(rectTop: 40)
        let second = Self.interiorTarget(rectTop: 140)
        let third = Self.interiorTarget(rectTop: 240)

        // Each sentence resolves somewhere new, so the convergence check in
        // `goToIndex` keeps moving the surface.
        #expect(first < second)
        #expect(second < third)
        #expect(second - first == 100)
        #expect(third - second == 100)

        // All three are ABOVE this resource's origin — the target reaches back
        // into the previous resource, which is what one continuous scroll
        // surface is for. (40 + 20 - 400 = -340.)
        #expect(first == -340)
        #expect(second == -240)
        #expect(third == -140)

        // The paired control, and the whole defect in three lines: the same
        // three sentences under the old floor all collapse to the SAME value,
        // which is what froze the surface.
        #expect(Self.interiorTarget(rectTop: 40, mayEnterPreviousResource: false) == 0)
        #expect(Self.interiorTarget(rectTop: 140, mayEnterPreviousResource: false) == 0)
        #expect(Self.interiorTarget(rectTop: 240, mayEnterPreviousResource: false) == 0)
    }

    /// The sentence really is centred, not merely "moved": its visible mass
    /// sits at 50% of the viewport once the container adds `yOffset(before:)`.
    @Test("a sentence at the head of an interior chapter centres its visible mass")
    func headOfChapterSentenceIsCentred() {
        let rectTop: CGFloat = 40
        let target = Self.interiorTarget(rectTop: rectTop)
        // Where the sentence's mass centre lands inside the viewport.
        #expect(rectTop + 20 - target == Self.viewportHeight / 2)
    }

    /// The band the floor used to swallow is ~half a viewport wide, and it
    /// widens with the sentence — a taller sentence's mass centre is deeper in.
    @Test("the swallowed band is half a viewport wide and scales with the sentence")
    func theSwallowedBandIsHalfAViewport() {
        // A hairline anchor: floor binds up to viewportHeight / 2.
        #expect(Self.interiorTarget(rectTop: 399, rectHeight: 0) < 0)
        #expect(Self.interiorTarget(rectTop: 400, rectHeight: 0) == 0)
        // A sentence taller than half the viewport contributes the capped
        // 400pt of mass, so the band shrinks to 200pt.
        #expect(Self.interiorTarget(rectTop: 199, rectHeight: 5000) < 0)
        #expect(Self.interiorTarget(rectTop: 200, rectHeight: 5000) == 0)
    }

    /// The inset geometries `aanelContinuousInsets` actually produces. Only
    /// the FIRST resource keeps a top inset and only the LAST keeps a bottom
    /// one — every interior resource gets both zeroed, and interior resources
    /// are exactly the chapters this fix is about.
    struct InsetGeometry: Sendable, CustomStringConvertible {
        let top: CGFloat
        let bottom: CGFloat
        let description: String
    }

    static let insetGeometries: [InsetGeometry] = [
        // The case that matters: both insets zero, so the entire safety margin
        // is `viewportHeight / 4` and `insetBottom` contributes nothing to it.
        InsetGeometry(top: 0, bottom: 0, description: "interior resource"),
        InsetGeometry(top: 60, bottom: 0, description: "first resource"),
        InsetGeometry(top: 0, bottom: 60, description: "last resource"),
        InsetGeometry(top: 60, bottom: 60, description: "single-resource book"),
    ]

    /// The invariant that makes dropping the upper bound safe:
    /// `ContinuousPaginationView.updateCurrentIndexFromViewport` resolves the
    /// index from `contentOffset.y + 1`, so as long as the target stays below
    /// this resource's `pageHeight`, `currentIndex` cannot flip forward and the
    /// `crossChapter` classification the detach logic depends on is preserved.
    ///
    /// Worst case is an anchor at the very bottom of the document. Swept across
    /// every inset geometry because the margin is NOT uniform: on an interior
    /// resource it is only `viewportHeight / 4`.
    @Test(
        "the viewport top stays inside the resource for any viewport and inset geometry",
        arguments: [CGFloat(320), 480, 800, 1200], insetGeometries
    )
    func viewportTopStaysInsideTheResource(viewportHeight: CGFloat, insets: InsetGeometry) {
        let documentHeight = Self.documentHeight
        let pageHeight = insets.top + documentHeight + insets.bottom

        // A sentence at least half a viewport tall maximises the target, and
        // so is the worst case; the shorter ones must also hold.
        for rectHeight in [CGFloat(0), 18, 40, 400, 5000] {
            let target = EPUBReflowableSpreadView.aanelCentredYOffset(
                rectTop: documentHeight,
                rectHeight: rectHeight,
                viewportHeight: viewportHeight,
                insetTop: insets.top,
                mayEnterPreviousResource: true
            )

            // `updateCurrentIndexFromViewport` probes at `contentOffset.y + 1`.
            #expect(target + 1 < pageHeight)

            // The margin the safety proof claims, with insetBottom excluded —
            // on an interior resource it is zero and cannot be leaned on.
            #expect(target <= insets.top + documentHeight - viewportHeight / 4)
        }
    }

    /// ...and the target really does need to exceed the old bound for a large
    /// enough viewport, which is precisely why the clamp broke centring.
    @Test("an anchor at the document end resolves past the old per-resource clamp")
    func anchorAtDocumentEndExceedsTheOldClamp() {
        #expect(Self.target(rectTop: Self.documentHeight) > Self.maxOffset)
    }
}
