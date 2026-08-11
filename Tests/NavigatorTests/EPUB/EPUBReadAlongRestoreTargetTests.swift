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
        // retry. Returning nil hands the restore to aanelLastSettledLocation —
        // roughly where the reader is. Falling back to the ACTIVE family
        // instead would yank a detached reader to the narration, the very
        // defect this rule exists to prevent.
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
