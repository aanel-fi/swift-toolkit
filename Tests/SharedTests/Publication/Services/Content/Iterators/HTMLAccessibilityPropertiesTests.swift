//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumShared
import Testing

/// Tests for the accessible name and description computation
/// (`HTMLAccessibilityProperties`), through the HTML content iterator.
///
/// This suite is mirrored one-for-one by the jest suite in
/// `Sources/Navigator/EPUB/Scripts/test/accname.test.ts` — keep the test
/// names aligned so the two can be diffed by eye.
struct HTMLAccessibilityPropertiesTests {
    // MARK: - Accessible name

    @Test func ariaLabelledbyResolvesMultipleIDsSkippingMissingOnes() async throws {
        let element = try await firstMediaElement("""
        <p id="l1">Hello</p><p id="l2">World</p>
        <img src="a.jpg" aria-labelledby="l1 missing l2"/>
        """)
        #expect(element?.accessibilityName == "Hello World")
    }

    @Test func ariaLabelledbyWithAllMissingIDsFallsThroughToAriaLabel() async throws {
        let element = try await firstMediaElement("""
        <img src="a.jpg" aria-labelledby="nope" aria-label="Label"/>
        """)
        #expect(element?.accessibilityName == "Label")
    }

    @Test func ariaLabelBeatsAlt() async throws {
        let element = try await firstMediaElement("""
        <img src="a.jpg" aria-label="Label" alt="Alt"/>
        """)
        #expect(element?.accessibilityName == "Label")
    }

    @Test func labelledbyTargetWithAriaLabelContributesItsLabel() async throws {
        let element = try await firstMediaElement("""
        <span id="l1" aria-label="Star">ignore me</span>
        <img src="a.jpg" aria-labelledby="l1"/>
        """)
        #expect(element?.accessibilityName == "Star")
    }

    @Test func labelledbyReferencedTextIsWhitespaceNormalized() async throws {
        let element = try await firstMediaElement("""
        <p id="l1">Hello
            beautiful   world</p>
        <img src="a.jpg" aria-labelledby="l1"/>
        """)
        #expect(element?.accessibilityName == "Hello beautiful world")
    }

    @Test func decorativeAltBlocksTitleAsName() async throws {
        let element = try await firstMediaElement("""
        <img src="a.jpg" alt="" title="Tooltip"/>
        """)
        #expect(element?.accessibilityName == nil)
        #expect(element?.accessibilityDescription == "Tooltip")
    }

    @Test func decorativeAltWithAriaLabelStillGetsAName() async throws {
        let element = try await firstMediaElement("""
        <img src="a.jpg" alt="" aria-label="Label"/>
        """)
        #expect(element?.accessibilityName == "Label")
    }

    @Test func titleFallbackIsConsumedByTheName() async throws {
        let element = try await firstMediaElement("""
        <img src="a.jpg" title="Tooltip"/>
        """)
        #expect(element?.accessibilityName == "Tooltip")
        #expect(element?.accessibilityDescription == nil)
    }

    // MARK: - Accessible description

    @Test func ariaDescribedbyProvidesTheDescription() async throws {
        let element = try await firstMediaElement("""
        <p id="d1">Long description.</p>
        <img src="a.jpg" alt="Alt" aria-describedby="d1"/>
        """)
        #expect(element?.accessibilityName == "Alt")
        #expect(element?.accessibilityDescription == "Long description.")
    }

    @Test func ariaDescriptionProvidesTheDescription() async throws {
        let element = try await firstMediaElement("""
        <img src="a.jpg" alt="Alt" aria-description="Long description."/>
        """)
        #expect(element?.accessibilityName == "Alt")
        #expect(element?.accessibilityDescription == "Long description.")
    }

    @Test func describedbyWithDanglingIDsStillStopsTheDescriptionCascade() async throws {
        let element = try await firstMediaElement("""
        <img src="a.jpg" alt="Alt" aria-describedby="missing" title="Tooltip"/>
        """)
        #expect(element?.accessibilityDescription == nil)
    }

    // MARK: - Suppression

    @Test func ariaHiddenSuppressesNameAndDescription() async throws {
        let element = try await firstMediaElement("""
        <img src="a.jpg" alt="Alt" aria-hidden="true" title="Tooltip"/>
        """)
        #expect(element?.accessibilityName == nil)
        #expect(element?.accessibilityDescription == nil)
    }

    @Test func presentationalRoleSuppressesNameAndDescription() async throws {
        let element = try await firstMediaElement("""
        <img src="a.jpg" alt="Alt" role="presentation"/>
        """)
        #expect(element?.accessibilityName == nil)
        #expect(element?.accessibilityDescription == nil)
    }

    @Test func globalARIAAttributeCancelsPresentationalRole() async throws {
        let element = try await firstMediaElement("""
        <img src="a.jpg" role="presentation" aria-label="Label"/>
        """)
        #expect(element?.accessibilityName == "Label")
    }

    @Test func ariaDescribedbyCancelsPresentationalRole() async throws {
        let element = try await firstMediaElement("""
        <p id="d1">D</p>
        <img src="a.jpg" alt="Alt" role="presentation" aria-describedby="d1"/>
        """)
        #expect(element?.accessibilityName == "Alt")
        #expect(element?.accessibilityDescription == "D")
    }

    @Test func ariaHiddenComparisonIsCaseInsensitive() async throws {
        let element = try await firstMediaElement("""
        <img src="a.jpg" alt="Alt" aria-hidden="TRUE"/>
        """)
        #expect(element?.accessibilityName == nil)
    }

    @Test func roleComparisonIsCaseInsensitive() async throws {
        let element = try await firstMediaElement("""
        <img src="a.jpg" alt="Alt" role="Presentation"/>
        """)
        #expect(element?.accessibilityName == nil)
    }

    // MARK: - SVG host-language sources

    @Test func svgTitleProvidesTheName() async throws {
        let element = try await firstMediaElement("""
        <svg><title>Chart title</title><circle/></svg>
        """)
        #expect(element?.accessibilityName == "Chart title")
    }

    @Test func svgDescProvidesTheDescription() async throws {
        let element = try await firstMediaElement("""
        <svg><title>Chart title</title><desc>Chart description</desc><circle/></svg>
        """)
        #expect(element?.accessibilityDescription == "Chart description")
    }

    // MARK: - Figcaption as name (HTML-AAM 4.1.10 step 4)

    @Test func figcaptionNamesAnImageWithNoOtherNameSource() async throws {
        let element = try await firstMediaElement("""
        <figure><img src="a.jpg"/><figcaption>Cap</figcaption></figure>
        """)
        let image = try #require(element as? ImageContentElement)
        #expect(image.accessibilityName == "Cap")
        #expect(image.caption == "Cap")
        #expect(image.text == "Cap")
    }

    @Test func figcaptionAsNameBlockedByOtherFlowContent() async throws {
        let element = try await firstMediaElement("""
        <figure><img src="a.jpg"/><p>Extra prose</p><figcaption>Cap</figcaption></figure>
        """)
        let image = try #require(element as? ImageContentElement)
        #expect(image.accessibilityName == nil)
        #expect(image.caption == "Cap")
    }

    @Test func figcaptionAsNameBlockedByASecondImage() async throws {
        let element = try await firstMediaElement("""
        <figure><img src="a.jpg"/><img src="b.jpg" alt="B"/><figcaption>Cap</figcaption></figure>
        """)
        #expect(element?.accessibilityName == nil)
    }

    @Test func figcaptionAsNameBlockedByAltAttribute() async throws {
        let element = try await firstMediaElement("""
        <figure><img src="a.jpg" alt=""/><figcaption>Cap</figcaption></figure>
        """)
        #expect(element?.accessibilityName == nil)
    }
}

// MARK: - Helpers

/// Iterates an HTML `body` fragment and returns the first non-text element
/// (image, SVG, audio or video), whose accessibility attributes are asserted.
private func firstMediaElement(_ body: String) async throws -> ContentElement? {
    let html = """
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml">
    <body>
    \(body)
    </body>
    </html>
    """

    let iter = HTMLResourceContentIterator(
        resource: DataResource(string: html),
        totalProgressionRange: { nil },
        locator: Locator(href: "dir/res.xhtml", mediaType: .xhtml)
    )

    while let element = try await iter.next() {
        if !(element is TextContentElement) {
            return element
        }
    }
    return nil
}
