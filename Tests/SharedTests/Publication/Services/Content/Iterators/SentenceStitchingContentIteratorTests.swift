//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumShared
import Testing

enum SentenceStitchingContentIteratorTests {
    struct PDFPages {
        @Test func sentenceAcrossTwoPagesWithHyphenation() async throws {
            let (iter, _) = makeIterator([
                pdfPage(1, "First sentence. There is a particu-"),
                pdfPage(2, "larly comfortable hotel. Second page done."),
            ])

            let first = try #require(try await iter.next() as? TextContentElement)
            let segments = first.segments
            #expect(segments.count == 3)

            // Prefix keeps its trailing whitespace so segment texts
            // concatenate to the exact spoken text.
            #expect(segments[0].text == "First sentence. ")

            // Part A drops the hyphen in its text but keeps the on-page form
            // in the highlight.
            #expect(segments[1].text == "There is a particu")
            #expect(segments[1].locator.text.highlight == "There is a particu-")
            #expect(segments[1].locator.locations.fragments == ["page=1"])
            #expect(segments[1].locator.text.after == "larly comfortable hotel.")

            // Part B is marked as a continuation and located on its own page.
            #expect(segments[2].text == "larly comfortable hotel.")
            #expect(segments[2].attribute(.continued) == ContentContinuationJoiner.direct)
            #expect(segments[2].locator.locations.fragments == ["page=2"])
            #expect(segments[2].locator.text.highlight == "larly comfortable hotel.")
            #expect((segments[2].locator.text.before?.count ?? 0) <= 50)

            // Element locations are untouched.
            #expect(first.locator.locations.fragments == ["page=1"])

            // The next element is trimmed of the moved head.
            let second = try #require(try await iter.next() as? TextContentElement)
            #expect(second.text == "Second page done.")
            #expect(second.locator.locations.fragments == ["page=2"])
        }

        @Test func spaceJoinedSentenceAcrossTwoPages() async throws {
            let (iter, _) = makeIterator([
                pdfPage(1, "The hungry cat sat on"),
                pdfPage(2, "the mat with style. Another sentence."),
            ])

            let first = try #require(try await iter.next() as? TextContentElement)
            #expect(first.segments.count == 2)
            #expect(first.segments[0].text == "The hungry cat sat on")
            #expect(first.segments[1].text == " the mat with style.")
            #expect(first.segments[1].locator.text.highlight == "the mat with style.")
            #expect(first.segments[1].attribute(.continued) == ContentContinuationJoiner.space)

            let second = try #require(try await iter.next() as? TextContentElement)
            #expect(second.text == "Another sentence.")
        }

        @Test func uppercaseContinuationKeepsHyphenAndSpace() async throws {
            let (iter, _) = makeIterator([
                pdfPage(1, "They visited Salt Lake-"),
                pdfPage(2, "City on their way westwards. Done."),
            ])

            let first = try #require(try await iter.next() as? TextContentElement)
            let last = try #require(first.segments.last)
            #expect(last.attribute(.continued) == ContentContinuationJoiner.space)
            #expect(first.segments.dropLast().last?.text.hasSuffix("Salt Lake-") == true)
            #expect(last.text == " City on their way westwards.")
        }

        @Test func terminalTailAvoidsLookahead() async throws {
            let (iter, mock) = makeIterator([
                pdfPage(1, "One two. Three."),
                pdfPage(2, "Second page."),
            ])

            let first = try #require(try await iter.next() as? TextContentElement)
            #expect(first.segments.count == 1)
            #expect(first.text == "One two. Three.")
            #expect(await mock.nextCallCount == 1)
            #expect(await mock.previousCallCount == 0)
        }

        @Test func abbreviationTailPassesFastPathWithoutMerging() async throws {
            let (iter, mock) = makeIterator([
                pdfPage(1, "He greeted Mr."),
                pdfPage(2, "Smith warmly. Done."),
            ])

            let first = try #require(try await iter.next() as? TextContentElement)
            #expect(first.text == "He greeted Mr.")
            #expect(await mock.nextCallCount == 1)
        }

        @Test func pageNumberTailKeepsFastPath() async throws {
            let (iter, mock) = makeIterator([
                pdfPage(1, "A full sentence.\n42"),
                pdfPage(2, "Second page."),
            ])

            let first = try #require(try await iter.next() as? TextContentElement)
            #expect(first.segments.count == 2)
            #expect(first.segments[0].text == "A full sentence.")
            #expect(first.segments[1].text == "42")
            #expect(first.segments[1].attribute(.pageArtifact) == PageArtifactKind.pageNumber)
            // The page number is neighbor-free, so the fast path still fires:
            // no lookahead was pulled.
            #expect(await mock.nextCallCount == 1)
        }

        @Test func runningFooterRequiresLookahead() async throws {
            let (iter, mock) = makeIterator([
                pdfPage(1, "A full sentence here.\nMy Great Book"),
                pdfPage(2, "Second page text here.\nMy Great Book"),
            ])

            let first = try #require(try await iter.next() as? TextContentElement)
            #expect(first.segments.count == 2)
            #expect(first.segments[0].text == "A full sentence here.")
            #expect(first.segments[1].text == "My Great Book")
            #expect(first.segments[1].attribute(.pageArtifact) == PageArtifactKind.runningHeader)
            // The footer can only be detected by comparing with the next
            // page, so the lookahead ran.
            #expect(await mock.nextCallCount == 2)

            let second = try #require(try await iter.next() as? TextContentElement)
            #expect(second.segments.count == 2)
            #expect(second.segments[0].text == "Second page text here.")
            #expect(second.segments[1].attribute(.pageArtifact) == PageArtifactKind.runningHeader)
        }

        @Test func threePageSentenceOnlyMergesFirstSeam() async throws {
            let (iter, _) = makeIterator([
                pdfPage(1, "The story begins with something very"),
                pdfPage(2, "strange that keeps going on and on"),
                pdfPage(3, "until it finally ends here. Done."),
            ])

            let first = try #require(try await iter.next() as? TextContentElement)
            #expect(first.text == "The story begins with something very strange that keeps going on and on")

            // The middle page moved entirely to the first one.
            let second = try #require(try await iter.next() as? TextContentElement)
            #expect(second.segments.isEmpty)

            // The second fragment of the sentence stays on the third page:
            // only the first seam is merged.
            let third = try #require(try await iter.next() as? TextContentElement)
            #expect(third.text == "until it finally ends here. Done.")
        }

        @Test func nonTextElementBreaksSeam() async throws {
            let (iter, _) = makeIterator([
                pdfPage(1, "An unfinished sentence that keeps"),
                imageElement(),
                pdfPage(2, "going strong. Done."),
            ])

            let first = try #require(try await iter.next() as? TextContentElement)
            #expect(first.text == "An unfinished sentence that keeps")
            #expect(try await iter.next() is ImageContentElement)
            let second = try #require(try await iter.next() as? TextContentElement)
            #expect(second.text == "going strong. Done.")
        }
    }

    struct FixedLayoutElements {
        @Test func pageNumberElementBetweenSentenceParts() async throws {
            let (iter, _) = makeIterator([
                fxlElement("p1.xhtml", "Intro sentence one."),
                fxlElement("p1.xhtml", "The hungry cat sat on"),
                fxlElement("p2.xhtml", "42"),
                fxlElement("p2.xhtml", "the mat with style. Another sentence here."),
            ])

            let first = try #require(try await iter.next() as? TextContentElement)
            #expect(first.text == "Intro sentence one.")

            // The seam merges past the standalone page number element.
            let second = try #require(try await iter.next() as? TextContentElement)
            #expect(second.segments.count == 2)
            #expect(second.segments[0].text == "The hungry cat sat on")
            #expect(second.segments[1].text == " the mat with style.")
            #expect(second.segments[1].attribute(.continued) == ContentContinuationJoiner.space)
            #expect(second.segments[1].locator.href.string == "p2.xhtml")

            // The page number element is marked, not removed.
            let third = try #require(try await iter.next() as? TextContentElement)
            #expect(third.text == "42")
            #expect(third.attribute(.pageArtifact) == PageArtifactKind.pageNumber)

            // The continuation was trimmed from the next page's element.
            let fourth = try #require(try await iter.next() as? TextContentElement)
            #expect(fourth.text == "Another sentence here.")
        }

        @Test func runningHeaderDetectedAcrossMultiElementPages() async throws {
            let (iter, _) = makeIterator([
                fxlElement("p1.xhtml", "My Book Title"),
                fxlElement("p1.xhtml", "Some sentence one."),
                fxlElement("p2.xhtml", "My Book Title"),
                fxlElement("p2.xhtml", "Some sentence two."),
            ])

            // The first page's header has no known neighbor yet.
            let first = try #require(try await iter.next() as? TextContentElement)
            #expect(first.attribute(.pageArtifact) == nil)

            let second = try #require(try await iter.next() as? TextContentElement)
            #expect(second.text == "Some sentence one.")

            // The second page's header matches the first page's head edge,
            // remembered across the multi-element page.
            let third = try #require(try await iter.next() as? TextContentElement)
            #expect(third.attribute(.pageArtifact) == PageArtifactKind.runningHeader)

            let fourth = try #require(try await iter.next() as? TextContentElement)
            #expect(fourth.text == "Some sentence two.")
        }

        @Test func sameResourceElementsAreNotStitched() async throws {
            let (iter, _) = makeIterator([
                fxlElement("c1.xhtml", "Sentence one runs and"),
                fxlElement("c1.xhtml", "then some more. Done."),
            ])

            let first = try #require(try await iter.next() as? TextContentElement)
            #expect(first.text == "Sentence one runs and")
            let second = try #require(try await iter.next() as? TextContentElement)
            #expect(second.text == "then some more. Done.")
        }
    }

    struct BackwardIteration {
        private let elements = [
            pdfPage(1, "First sentence. There is a particu-"),
            pdfPage(2, "larly comfortable hotel. Second page done."),
        ]

        @Test func backwardFromEndEqualsReversedForward() async throws {
            let (forward, _) = makeIterator(elements)
            var forwardElements: [AnyEquatableContentElement] = []
            while let element = try await forward.next() {
                forwardElements.append(element.equatable())
            }

            let (backward, _) = makeIterator(elements, startingAtEnd: true)
            var backwardElements: [AnyEquatableContentElement] = []
            while let element = try await backward.previous() {
                backwardElements.append(element.equatable())
            }

            #expect(backwardElements == forwardElements.reversed())
        }

        @Test func alternatingDirectionsIsConsistent() async throws {
            let (iter, _) = makeIterator(elements)
            let first = try #require(try await iter.next()).equatable()
            let second = try #require(try await iter.next()).equatable()
            let backToFirst = try #require(try await iter.previous()).equatable()
            let secondAgain = try #require(try await iter.next()).equatable()

            #expect(backToFirst == first)
            #expect(secondAgain == second)
        }
    }
}

// MARK: - Helpers

private func pdfPage(_ number: Int, _ text: String) -> TextContentElement {
    let locator = Locator(href: "book.pdf", mediaType: .pdf).copy(
        locations: {
            $0.fragments = ["page=\(number)"]
            $0.position = number
        },
        text: {
            $0 = Locator.Text(highlight: text)
        }
    )
    return TextContentElement(
        locator: locator,
        role: .body,
        segments: [TextContentElement.Segment(locator: locator, text: text)]
    )
}

private func fxlElement(_ href: String, _ text: String) -> TextContentElement {
    let locator = Locator(href: href, mediaType: .xhtml).copy(
        text: {
            $0 = Locator.Text(highlight: text)
        }
    )
    return TextContentElement(
        locator: locator,
        role: .body,
        segments: [TextContentElement.Segment(locator: locator, text: text)]
    )
}

private func imageElement() -> ImageContentElement {
    ImageContentElement(
        locator: Locator(href: "img.png", mediaType: .png),
        embeddedLink: Link(href: "img.png")
    )
}

private func makeIterator(
    _ elements: [ContentElement],
    startingAtEnd: Bool = false
) -> (SentenceStitchingContentIterator, MockContentIterator) {
    let mock = MockContentIterator(elements, startingAtEnd: startingAtEnd)
    let iterator = SentenceStitchingContentIterator(iterator: mock, language: Language(code: .bcp47("en")))
    return (iterator, mock)
}

/// A `ContentIterator` over a fixed list of elements, with the same cursor
/// semantics as `PDFResourceContentIterator`, counting the calls it receives.
actor MockContentIterator: ContentIterator {
    private let elements: [ContentElement]

    /// Index of the last returned element.
    private var index: Int?

    private(set) var nextCallCount = 0
    private(set) var previousCallCount = 0

    init(_ elements: [ContentElement], startingAtEnd: Bool = false) {
        self.elements = elements
        index = startingAtEnd ? elements.count : nil
    }

    func next() async throws -> ContentElement? {
        nextCallCount += 1
        let target = (index ?? -1) + 1
        guard elements.indices.contains(target) else {
            return nil
        }
        index = target
        return elements[target]
    }

    func previous() async throws -> ContentElement? {
        previousCallCount += 1
        let target = (index ?? 0) - 1
        guard elements.indices.contains(target) else {
            return nil
        }
        index = target
        return elements[target]
    }
}
