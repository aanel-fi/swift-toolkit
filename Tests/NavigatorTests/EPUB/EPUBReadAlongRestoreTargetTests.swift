//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import ReadiumShared
import Testing

// MARK: - Fixtures

private func makeLocator(href: String, highlight: String?) -> Locator {
    Locator(
        href: AnyURL(string: href)!,
        mediaType: .xhtml,
        text: highlight.map { Locator.Text(highlight: $0) } ?? Locator.Text()
    )
}

private func makeGroup(
    _ name: String,
    href: String,
    highlight: String?
) -> (DecorationGroup, [DiffableDecoration]) {
    (
        name,
        [DiffableDecoration(decoration: Decoration(
            id: "\(name)@\(href)",
            locator: makeLocator(href: href, highlight: highlight),
            style: .highlight(tint: nil, isActive: true)
        ))]
    )
}

/// The six active-sentence variants the app can apply at once. Every variant
/// of a family carries the SAME locator, so which variant is picked within a
/// family never changes the answer.
private func activeGroups(
    href: String = "chapter4.xhtml",
    highlight: String = "the narrated sentence"
) -> [DecorationGroup: [DiffableDecoration]] {
    Dictionary(uniqueKeysWithValues: [
        "read-along-sidemark",
        "read-along-underline",
        "read-along-bg-blue",
        "read-along-bg-pink",
        "read-along-bg-pistachio",
        "read-along-bg-yellow",
    ].map { makeGroup($0, href: href, highlight: highlight) })
}

/// The two resume-preview variants, applied ONLY while follow is detached.
private func resumeGroups(
    href: String = "chapter5.xhtml",
    highlight: String? = "the on-screen sentence"
) -> [DecorationGroup: [DiffableDecoration]] {
    Dictionary(uniqueKeysWithValues: [
        "read-along-resume-sidemark",
        "read-along-resume-bg-yellow",
    ].map { makeGroup($0, href: href, highlight: highlight) })
}

private func restoreTarget(
    _ decorations: [DecorationGroup: [DiffableDecoration]]
) -> Locator? {
    EPUBNavigatorViewController.aanelReadAlongRestoreLocator(in: decorations)
}

// MARK: - Tests

/// aanel: the mode-switch reload's read-along restore target.
///
/// Before the family-precedence rule these expectations were HASH-ORDER
/// dependent: the pick came off `Dictionary.first`, so with both families
/// applied it landed on the resume marker or on the narrated sentence
/// depending on the process's hash seed. A run could pass by luck; a build
/// could ship either behaviour.
@Suite("Read-along restore target")
struct EPUBReadAlongRestoreTargetTests {
    @Test("detached: the resume marker outranks the narrated sentence")
    func resumeMarkerWinsWhenBothFamiliesApplied() {
        let target = restoreTarget(activeGroups().merging(resumeGroups()) { a, _ in a })
        #expect(target?.text.highlight == "the on-screen sentence")
        #expect(target?.href.string == "chapter5.xhtml")
    }

    @Test("attached: with no resume marker the narrated sentence is the target")
    func activeSentenceWinsWhenAttached() {
        #expect(restoreTarget(activeGroups())?.text.highlight == "the narrated sentence")
    }

    @Test("no read-along decoration yields no target")
    func noReadAlongGroups() {
        let decorations = Dictionary(uniqueKeysWithValues: [
            makeGroup("bookmarks", href: "chapter1.xhtml", highlight: "elsewhere"),
            makeGroup("search", href: "chapter2.xhtml", highlight: "elsewhere"),
        ])
        #expect(restoreTarget(decorations) == nil)
    }

    @Test("an emptied resume group does not outrank a live active sentence")
    func emptiedResumeGroupsAreIgnored() {
        var decorations = activeGroups()
        decorations["read-along-resume-sidemark"] = []
        decorations["read-along-resume-bg-yellow"] = []
        #expect(restoreTarget(decorations)?.text.highlight == "the narrated sentence")
    }

    @Test("an unanchored resume marker falls through to the geometric restore, not to the narration")
    func unanchoredResumeMarkerYieldsNoTarget() {
        // Highlight-less locators cannot be centred by the reload's anchor
        // retry. Returning nil hands the restore to the centre answer (step
        // 2c) — where the reader was looking. Falling back to the ACTIVE
        // family instead would yank a detached reader to the narration, the
        // very defect this rule exists to prevent.
        let decorations = activeGroups().merging(resumeGroups(highlight: nil)) { a, _ in a }
        #expect(restoreTarget(decorations) == nil)
    }

    @Test("the within-family pick is deterministic, not hash-ordered")
    func withinFamilyPickIsDeterministic() {
        // Artificial: in production every variant of a family shares one
        // locator. Distinct locators here prove the pick is by sorted key
        // rather than by Dictionary order.
        let decorations = Dictionary(uniqueKeysWithValues: [
            makeGroup("read-along-sidemark", href: "c.xhtml", highlight: "sidemark"),
            makeGroup("read-along-underline", href: "c.xhtml", highlight: "underline"),
            makeGroup("read-along-bg-yellow", href: "c.xhtml", highlight: "bg-yellow"),
        ])
        // "read-along-bg-yellow" sorts first.
        for _ in 0 ..< 50 {
            #expect(restoreTarget(decorations)?.text.highlight == "bg-yellow")
        }
    }
}

/// aanel: pairing the restore's sentence anchor with the centre answer —
/// reader native migration Phase 2 step 2c.
///
/// The drift these cover is a **reference-point** bug, not a landing one. A
/// Readium location names the viewport TOP (Rulla) or the page's leading edge
/// (Sivut); the resume marker has been resolved from the CENTRE since step 2b;
/// and both surfaces read a progression target as a centre. Restoring from a
/// top-referenced locator therefore moved the reader back half a viewport per
/// container swap, twice per Sivut↔Rulla round trip, without cancelling.
@Suite("Restore target: sentence anchor + centre fallback")
struct EPUBRestoreTargetTests {
    private func centre(href: String, progression: Double) -> Locator {
        var locations = Locator.Locations()
        locations.progression = progression
        return Locator(href: AnyURL(string: href)!, mediaType: .xhtml, locations: locations)
    }

    @Test("a sentence keeps its anchor AND gains the centre's progression")
    func sentenceGainsCentreProgression() {
        let merged = EPUBNavigatorViewController.aanelRestoreTarget(
            sentence: makeLocator(href: "chapter5.xhtml", highlight: "the on-screen sentence"),
            centre: centre(href: "chapter5.xhtml", progression: 0.42)
        )
        // Both halves, or the merge is pointless: the anchor is what lands the
        // restore exactly, the progression is the fallback when it misses.
        #expect(merged?.text.highlight == "the on-screen sentence")
        #expect(merged?.locations.progression == 0.42)
    }

    @Test("hrefs are matched by suffix, since sidecar and reading-order forms differ")
    func hrefSuffixMatch() {
        let merged = EPUBNavigatorViewController.aanelRestoreTarget(
            sentence: makeLocator(href: "chapter5.xhtml", highlight: "sentence"),
            centre: centre(href: "OEBPS/chapter5.xhtml", progression: 0.42)
        )
        #expect(merged?.locations.progression == 0.42)
    }

    @Test("a centre in a DIFFERENT resource is not attached")
    func centreFromAnotherResourceIsRejected() {
        // At a chapter seam on the continuous surface the centre and the
        // decorated sentence legitimately name adjacent resources
        // (read-along.md FR-RA-11.7b). A progression from the neighbour would
        // be a fallback pointing into the wrong document.
        let merged = EPUBNavigatorViewController.aanelRestoreTarget(
            sentence: makeLocator(href: "chapter5.xhtml", highlight: "sentence"),
            centre: centre(href: "chapter6.xhtml", progression: 0.42)
        )
        #expect(merged?.text.highlight == "sentence")
        #expect(merged?.locations.progression == nil)
    }

    @Test("with no sentence the centre IS the restore target")
    func centreAloneIsTheTarget() {
        // The no-read-along case: plain reading, or every highlight variant
        // switched off. Before 2c this fell to the settled location, which is
        // the top-referenced answer the drift came from.
        let target = EPUBNavigatorViewController.aanelRestoreTarget(
            sentence: nil,
            centre: centre(href: "chapter5.xhtml", progression: 0.42)
        )
        #expect(target?.locations.progression == 0.42)
        #expect(target?.text.highlight == nil)
    }

    @Test("with neither, there is no target and the caller falls through")
    func noSentenceNoCentre() {
        #expect(EPUBNavigatorViewController.aanelRestoreTarget(sentence: nil, centre: nil) == nil)
    }

    @Test("a centre carrying no progression is not attached")
    func centreWithoutProgressionIsIgnored() {
        let merged = EPUBNavigatorViewController.aanelRestoreTarget(
            sentence: makeLocator(href: "chapter5.xhtml", highlight: "sentence"),
            centre: Locator(href: AnyURL(string: "chapter5.xhtml")!, mediaType: .xhtml)
        )
        #expect(merged?.locations.progression == nil)
    }
}
