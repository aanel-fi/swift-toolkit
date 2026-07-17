//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation

/// A `ContentIterator` decorator which re-balances text across fixed-layout
/// page boundaries (seams), so that no element ends mid-sentence.
///
/// Fixed-layout content (PDF, EPUB FXL) is paginated by construction: a
/// sentence cut by a page break is split between two elements, and stray page
/// text (page numbers, running headers) sits between the two halves. This
/// iterator:
///
/// - marks page artifacts with the `pageArtifact` content attribute, per line
///   (PDF page blobs) or per element (FXL standalone elements);
/// - when a sentence spans a seam, moves the continuation onto the element
///   where the sentence starts, as an extra segment marked `continued` with a
///   locator targeting its own page. The next element is trimmed of the moved
///   head.
///
/// Known limitations:
/// - A sentence spanning 3+ pages is only merged across the first seam.
/// - A page ending with an abbreviation ("...said Mr.") is not merged, as the
///   terminal punctuation fast path skips the lookahead.
public actor SentenceStitchingContentIterator: ContentIterator, Loggable {
    private let buffered: BufferedContentIterator
    private let language: Language?
    private let artifactDetectors: [PageArtifactDetector]
    private let textTokenizerFactory: @Sendable (Language?) -> TextTokenizer

    /// Maximum number of page artifact lines (or elements) stripped from each
    /// page edge.
    private let maxArtifactsPerEdge = 3

    /// Maximum amount of text considered on each side of a seam when looking
    /// for a spanning sentence.
    private let seamChunkLength = 600

    /// Length of the `before` and `after` context snippets in the produced
    /// locators.
    private let contextSnippetLength = 50

    public init(
        iterator: ContentIterator,
        language: Language? = nil,
        artifactDetectors: [PageArtifactDetector] = [PageNumberArtifactDetector(), RunningHeaderArtifactDetector()],
        textTokenizerFactory: @escaping @Sendable (Language?) -> TextTokenizer = {
            makeDefaultTextTokenizer(unit: .sentence, language: $0)
        }
    ) {
        buffered = BufferedContentIterator(iterator)
        self.language = language
        self.artifactDetectors = artifactDetectors
        self.textTokenizerFactory = textTokenizerFactory
    }

    /// Whether an element was already returned by this iterator.
    ///
    /// The head of the very first element returned going forward is kept
    /// untouched: when starting mid-publication, trimming it would silently
    /// drop the continuation of a sentence started on the previous page.
    private var hasReturnedElement = false

    public func next() async throws -> ContentElement? {
        guard let raw = try await buffered.next() else {
            return nil
        }
        defer { hasReturnedElement = true }
        return try await process(raw, skippingHeadSeam: !hasReturnedElement)
    }

    public func previous() async throws -> ContentElement? {
        guard let raw = try await buffered.previous() else {
            return nil
        }
        defer { hasReturnedElement = true }
        return try await process(raw, skippingHeadSeam: false)
    }

    // MARK: - Page identity

    /// Identifies the fixed-layout page an element belongs to.
    ///
    /// Elements from different resources, or from the same resource with
    /// different `page=` fragments (PDF), are on different pages.
    private struct PageIdentity: Hashable {
        let href: String
        let pageFragment: String?

        init(of element: ContentElement) {
            href = element.locator.href.string
            pageFragment = element.locator.locations.fragments
                .first { $0.lowercased().hasPrefix("page=") }?
                .lowercased()
        }

        /// Whether the element holds the text of a whole page (PDF), as
        /// opposed to being one of several elements on its page (FXL).
        var isPageBlob: Bool {
            pageFragment != nil
        }
    }

    // MARK: - Element processing

    /// Returns the stitched form of a raw element.
    ///
    /// The result is a pure function of the raw element and its raw
    /// neighbors, so that `next()` and `previous()` produce consistent
    /// elements in any order of traversal.
    private func process(_ raw: ContentElement, skippingHeadSeam: Bool) async throws -> ContentElement {
        guard let element = raw as? TextContentElement else {
            return raw
        }
        let page = PageIdentity(of: element)

        if page.isPageBlob {
            recordBlobEdges(of: element, page: page)
            return try await processPageBlob(element, page: page, skippingHeadSeam: skippingHeadSeam)
        } else {
            return try await processPageElement(element, page: page, skippingHeadSeam: skippingHeadSeam)
        }
    }

    /// Processes a whole-page text blob (PDF page): strips artifact lines at
    /// both edges and stitches sentences across both seams.
    private func processPageBlob(_ element: TextContentElement, page: PageIdentity, skippingHeadSeam: Bool) async throws -> ContentElement {
        guard let base = element.segments.first else {
            return element
        }
        let rawText = element.text ?? ""
        guard !trimmed(rawText).isEmpty else {
            return element
        }

        let leftSeam: Seam? = skippingHeadSeam
            ? nil
            : try await seamOnLeft(of: element, page: page)
        let rightSeam = try await seamOnRight(of: element, page: page, rawText: rawText)

        let headArtifacts = (leftSeam?.rightPartnerLocator == element.locator)
            ? (leftSeam?.rightHeadArtifacts ?? []) : []
        let headMerge = (leftSeam?.rightPartnerLocator == element.locator)
            ? leftSeam?.merge : nil
        let tailArtifacts = (rightSeam?.leftPartnerLocator == element.locator)
            ? (rightSeam?.leftTailArtifacts ?? []) : []
        let tailMerge = (rightSeam?.leftPartnerLocator == element.locator)
            ? rightSeam?.merge : nil

        guard !(headArtifacts.isEmpty && tailArtifacts.isEmpty && headMerge == nil && tailMerge == nil) else {
            return element
        }

        var body = removingHeadLines(headArtifacts, from: rawText)
        var bodyBefore: String? = nil

        if let merge = headMerge {
            body = trimmingHead(body)
            if body.hasPrefix(merge.partBOnPage) {
                body = trimmingHead(String(body.dropFirst(merge.partBOnPage.count)))
                bodyBefore = String(merge.partBOnPage.suffix(contextSnippetLength))
            } else {
                log(.warning, "Seam continuation is not a prefix of the page body")
            }
        }

        body = removingTailLines(tailArtifacts, from: body)

        var mergeSegments: [TextContentElement.Segment] = []
        if let merge = tailMerge {
            body = trimmingTail(body)
            if body.hasSuffix(merge.partAOnPage) {
                let prefix = String(body.dropLast(merge.partAOnPage.count))
                mergeSegments = makeMergeSegments(
                    merge,
                    prefix: prefix,
                    baseLocator: element.locator,
                    baseAttributes: base.attributes
                )
                body = prefix
            } else {
                log(.warning, "Seam sentence part is not a suffix of the page body")
            }
        }

        var segments: [TextContentElement.Segment] = []
        segments += headArtifacts.map {
            makeArtifactSegment($0, locator: element.locator, baseAttributes: base.attributes)
        }
        if !trimmed(body).isEmpty, mergeSegments.isEmpty {
            segments.append(TextContentElement.Segment(
                locator: element.locator.copy(text: {
                    $0 = Locator.Text(before: bodyBefore, highlight: body)
                }),
                text: body,
                attributes: base.attributes
            ))
        }
        segments += mergeSegments
        segments += tailArtifacts.map {
            makeArtifactSegment($0, locator: element.locator, baseAttributes: base.attributes)
        }

        var result = element
        result.segments = segments
        result.locator = element.locator.copy(text: {
            $0 = Locator.Text(highlight: segments.map(\.text).joined())
        })
        return result
    }

    /// Processes one element of a multi-element fixed-layout page (EPUB FXL):
    /// marks whole-element artifacts at page edges, and stitches sentences at
    /// the cross-page seams of the page's first and last text elements.
    private func processPageElement(_ element: TextContentElement, page: PageIdentity, skippingHeadSeam: Bool) async throws -> ContentElement {
        guard !element.segments.isEmpty, let rawText = element.text, !trimmed(rawText).isEmpty else {
            return element
        }
        let endsSentence = endsWithTerminalPunctuation(rawText)

        // The fast path: an element ending a sentence cannot be an artifact
        // and needs no tail seam, so we don't pull any lookahead for it.
        if !endsSentence {
            let isHeadEdge = try await isAtPageEdge(.head, element: element, page: page)
            let isTailEdge = try await isAtPageEdge(.tail, element: element, page: page)

            var edges: [PageArtifactCandidate.Edge] = []
            if isHeadEdge { edges.append(.head) }
            if isTailEdge { edges.append(.tail) }

            if !edges.isEmpty,
               let kind = wholeElementArtifactKind(of: element, page: page, edges: edges)
            {
                var result = element
                result.attributes.append(ContentAttribute(key: .pageArtifact, value: kind))
                return result
            }
        }

        var result = element
        var changed = false

        // Head seam: trim the sentence head which moved to the previous page.
        if !skippingHeadSeam,
           let seam = try await seamOnLeft(of: element, page: page),
           seam.rightPartnerLocator == element.locator,
           let merge = seam.merge,
           var segment = result.segments.first
        {
            let text = trimmingHead(segment.text)
            if text.hasPrefix(merge.partBOnPage) {
                let remainder = trimmingHead(String(text.dropFirst(merge.partBOnPage.count)))
                if trimmed(remainder).isEmpty {
                    result.segments.removeFirst()
                } else {
                    segment.text = remainder
                    segment.locator = segment.locator.copy(text: {
                        $0 = Locator.Text(
                            before: String(merge.partBOnPage.suffix(self.contextSnippetLength)),
                            highlight: remainder
                        )
                    })
                    result.segments[0] = segment
                }
                changed = true
            } else {
                log(.warning, "Seam continuation is not a prefix of the element text")
            }
        }

        // Tail seam: append the continuation of the sentence started here.
        if !endsSentence,
           let seam = try await seamOnRight(of: element, page: page, rawText: rawText),
           seam.leftPartnerLocator == element.locator,
           let merge = seam.merge,
           let segment = result.segments.last
        {
            let text = trimmingTail(segment.text)
            if text.hasSuffix(merge.partAOnPage) {
                let prefix = String(text.dropLast(merge.partAOnPage.count))
                result.segments.removeLast()
                result.segments += makeMergeSegments(
                    merge,
                    prefix: prefix,
                    baseLocator: element.locator,
                    baseAttributes: segment.attributes
                )
                changed = true
            } else {
                log(.warning, "Seam sentence part is not a suffix of the element text")
            }
        }

        if changed {
            result.locator = result.locator.copy(text: {
                $0 = Locator.Text(highlight: result.segments.map(\.text).joined())
            })
        }
        return result
    }

    /// Builds the linked per-page segments representing a merged cross-page
    /// sentence: the part on this page, then the continuation located on the
    /// next page and marked `continued`.
    private func makeMergeSegments(
        _ merge: Seam.Merge,
        prefix: String,
        baseLocator: Locator,
        baseAttributes: [ContentAttribute]
    ) -> [TextContentElement.Segment] {
        var segments: [TextContentElement.Segment] = []

        if !trimmed(prefix).isEmpty {
            segments.append(TextContentElement.Segment(
                locator: baseLocator.copy(text: {
                    $0 = Locator.Text(
                        after: String(merge.partAOnPage.prefix(self.contextSnippetLength)),
                        highlight: prefix
                    )
                }),
                text: prefix,
                attributes: baseAttributes
            ))
        }

        segments.append(TextContentElement.Segment(
            locator: baseLocator.copy(text: {
                $0 = Locator.Text(
                    after: String(self.trimmed(merge.partBSpoken).prefix(self.contextSnippetLength)),
                    before: Optional(String(prefix.suffix(self.contextSnippetLength))).takeIf { !$0.isEmpty },
                    highlight: merge.partAOnPage
                )
            }),
            text: merge.partASpoken,
            attributes: baseAttributes
        ))

        segments.append(TextContentElement.Segment(
            locator: merge.rightLocator.copy(text: {
                $0 = Locator.Text(
                    after: merge.partBAfterContext,
                    before: String((prefix + merge.partAOnPage).suffix(self.contextSnippetLength)),
                    highlight: merge.partBOnPage
                )
            }),
            text: merge.partBSpoken,
            attributes: baseAttributes + [ContentAttribute(key: .continued, value: merge.joiner)]
        ))

        return segments
    }

    private func makeArtifactSegment(_ artifact: Seam.Artifact, locator: Locator, baseAttributes: [ContentAttribute]) -> TextContentElement.Segment {
        TextContentElement.Segment(
            locator: locator.copy(text: {
                $0 = Locator.Text(highlight: artifact.text)
            }),
            text: artifact.text,
            attributes: baseAttributes + [ContentAttribute(key: .pageArtifact, value: artifact.kind)]
        )
    }

    /// Returns whether `element` sits at the given edge of its page,
    /// looking past standalone artifact elements, and records the observed
    /// page adjacencies and edge texts along the way.
    private func isAtPageEdge(_ edge: PageArtifactCandidate.Edge, element: TextContentElement, page: PageIdentity) async throws -> Bool {
        for step in 1 ... maxArtifactsPerEdge {
            let peeked: ContentElement?
            switch edge {
            case .head: peeked = try await buffered.peekBefore(step)
            case .tail: peeked = try await buffered.peekAfter(step)
            }
            guard let peeked else {
                recordEdge(edge, of: page, element: element)
                return true
            }
            guard let text = peeked as? TextContentElement else {
                return true
            }
            let peekedPage = PageIdentity(of: text)
            if peekedPage != page {
                switch edge {
                case .head:
                    recordAdjacency(left: peekedPage, right: page)
                    recordEdge(.tail, of: peekedPage, element: text)
                    recordEdge(.head, of: page, element: element)
                case .tail:
                    recordAdjacency(left: page, right: peekedPage)
                    recordEdge(.tail, of: page, element: element)
                    recordEdge(.head, of: peekedPage, element: text)
                }
                return true
            }
            if !peekedPage.isPageBlob, wholeElementArtifactKind(of: text, page: peekedPage) != nil {
                continue
            }
            return false
        }
        return false
    }

    // MARK: - Seams

    /// The effects of a page boundary on the two elements surrounding it.
    ///
    /// A seam is a pure function of the two partner elements (and the
    /// recorded neighboring page edges); it is cached and reused when the
    /// other partner is processed, in either direction of iteration.
    private struct Seam {
        /// Locator of the left partner element, the last text element before
        /// the boundary.
        var leftPartnerLocator: Locator

        /// Locator of the right partner element, the first text element after
        /// the boundary.
        var rightPartnerLocator: Locator

        /// Artifact lines stripped from the tail of the left partner, in
        /// on-page order.
        var leftTailArtifacts: [Artifact] = []

        /// Artifact lines stripped from the head of the right partner, in
        /// on-page order.
        var rightHeadArtifacts: [Artifact] = []

        /// The sentence spanning the boundary, if any.
        var merge: Merge?

        struct Artifact {
            /// Trimmed text of the artifact line.
            var text: String
            var kind: PageArtifactKind
        }

        struct Merge {
            /// Trailing part of the sentence's first half, as it appears on
            /// the left page (e.g. "particu-").
            var partAOnPage: String

            /// Spoken form of the first half (e.g. "particu", hyphen
            /// dropped when de-hyphenated).
            var partASpoken: String

            /// Leading part of the sentence's second half, as it appears on
            /// the right page (e.g. "larly.").
            var partBOnPage: String

            /// Spoken form of the second half, with its joining space when
            /// the halves are separate words.
            var partBSpoken: String

            var joiner: ContentContinuationJoiner

            /// Locator of the right partner element, used to locate the
            /// continuation segment on its own page.
            var rightLocator: Locator

            /// Up to `contextSnippetLength` characters following the
            /// continuation on the right page.
            var partBAfterContext: String?
        }
    }

    private struct SeamKey: Hashable {
        var left: PageIdentity
        var right: PageIdentity
    }

    private var seamCache: [SeamKey: Seam] = [:]
    private var seamCacheOrder: [SeamKey] = []

    private func cacheSeam(_ seam: Seam, for key: SeamKey) {
        if seamCache.updateValue(seam, forKey: key) == nil {
            seamCacheOrder.append(key)
            while seamCacheOrder.count > 16 {
                seamCache.removeValue(forKey: seamCacheOrder.removeFirst())
            }
        }
    }

    private func cachedSeam(where predicate: (SeamKey) -> Bool) -> Seam? {
        seamCache.first { predicate($0.key) }?.value
    }

    /// Returns the seam at the tail of `element`, or `nil` when nothing
    /// applies (mid-page element, non-text neighbor, end of publication).
    ///
    /// Fast path: when the tail — after stripping artifacts detectable
    /// without neighbors — ends a sentence, no lookahead is pulled and the
    /// seam carries only the found artifacts.
    private func seamOnRight(of element: TextContentElement, page: PageIdentity, rawText: String) async throws -> Seam? {
        if let cached = cachedSeam(where: { $0.left == page }) {
            return cached
        }

        // Fast-path gate, using only neighbor-free detectors.
        if page.isPageBlob {
            let artifacts = tailLineArtifacts(
                in: rawText,
                neighborsAvailable: false,
                previousEdgeLines: [],
                nextEdgeLines: []
            )
            let body = trimmed(removingTailLines(artifacts, from: rawText))
            if body.isEmpty || endsWithTerminalPunctuation(body) {
                return Seam(
                    leftPartnerLocator: element.locator,
                    rightPartnerLocator: element.locator,
                    leftTailArtifacts: artifacts
                )
            }
        } else if endsWithTerminalPunctuation(rawText) {
            return nil
        }

        guard let (partner, partnerPage) = try await findPartner(of: element, page: page, direction: .forward) else {
            // No stitchable partner: still mark the tail artifacts we can
            // detect with the recorded page edges.
            guard page.isPageBlob else {
                return nil
            }
            let artifacts = tailLineArtifacts(
                in: rawText,
                neighborsAvailable: true,
                previousEdgeLines: neighborEdgeLines(of: page, edge: .tail, side: .previous),
                nextEdgeLines: neighborEdgeLines(of: page, edge: .tail, side: .next)
            )
            guard !artifacts.isEmpty else {
                return nil
            }
            return Seam(
                leftPartnerLocator: element.locator,
                rightPartnerLocator: element.locator,
                leftTailArtifacts: artifacts
            )
        }

        let key = SeamKey(left: page, right: partnerPage)
        let seam = try computeSeam(left: element, leftPage: page, right: partner, rightPage: partnerPage)
        cacheSeam(seam, for: key)
        return seam
    }

    /// Returns the seam at the head of `element`, or `nil` when nothing
    /// applies.
    private func seamOnLeft(of element: TextContentElement, page: PageIdentity) async throws -> Seam? {
        if let cached = cachedSeam(where: { $0.right == page }) {
            return cached
        }

        guard let (partner, partnerPage) = try await findPartner(of: element, page: page, direction: .backward) else {
            return nil
        }

        let key = SeamKey(left: partnerPage, right: page)
        let seam = try computeSeam(left: partner, leftPage: partnerPage, right: element, rightPage: page)
        cacheSeam(seam, for: key)
        return seam
    }

    private enum Direction {
        case forward, backward
    }

    /// Walks the raw elements from `element` to find its stitching partner
    /// across the page boundary, skipping up to `maxArtifactsPerEdge - 1`
    /// standalone artifact elements sitting between the two sentence parts.
    ///
    /// Returns `nil` when `element` is not at the edge of its page, or when
    /// the boundary is not stitchable (non-text neighbor, end of the
    /// publication).
    private func findPartner(
        of element: TextContentElement,
        page: PageIdentity,
        direction: Direction
    ) async throws -> (TextContentElement, PageIdentity)? {
        for step in 1 ... maxArtifactsPerEdge {
            let peeked: ContentElement?
            switch direction {
            case .forward: peeked = try await buffered.peekAfter(step)
            case .backward: peeked = try await buffered.peekBefore(step)
            }
            guard let peeked, let text = peeked as? TextContentElement else {
                return nil
            }

            let peekedPage = PageIdentity(of: text)
            if peekedPage.isPageBlob {
                recordBlobEdges(of: text, page: peekedPage)
            }

            if peekedPage == page {
                // A standalone artifact on the same page keeps the walk
                // going; regular same-page text means `element` is not at the
                // page edge.
                if !peekedPage.isPageBlob, wholeElementArtifactKind(of: text, page: peekedPage) != nil {
                    continue
                }
                return nil
            }

            switch direction {
            case .forward: recordAdjacency(left: page, right: peekedPage)
            case .backward: recordAdjacency(left: peekedPage, right: page)
            }

            if !peekedPage.isPageBlob, wholeElementArtifactKind(of: text, page: peekedPage) != nil {
                continue
            }

            if !peekedPage.isPageBlob {
                switch direction {
                case .forward: recordEdge(.head, of: peekedPage, element: text)
                case .backward: recordEdge(.tail, of: peekedPage, element: text)
                }
            }
            return (text, peekedPage)
        }
        return nil
    }

    /// Computes the seam between the two partner elements: full artifact
    /// detection at both edges, then sentence merge on the remaining bodies.
    private func computeSeam(
        left: TextContentElement,
        leftPage: PageIdentity,
        right: TextContentElement,
        rightPage: PageIdentity
    ) throws -> Seam {
        var seam = Seam(
            leftPartnerLocator: left.locator,
            rightPartnerLocator: right.locator
        )

        let leftRaw = left.segments.last?.text ?? ""
        let rightRaw = right.segments.first?.text ?? ""

        var leftBody = leftRaw
        if leftPage.isPageBlob {
            let leftText = left.text ?? ""
            seam.leftTailArtifacts = tailLineArtifacts(
                in: leftText,
                neighborsAvailable: true,
                previousEdgeLines: neighborEdgeLines(of: leftPage, edge: .tail, side: .previous),
                nextEdgeLines: rightPage.isPageBlob
                    ? edgeLines(.tail, of: right.text ?? "")
                    : (pageEdges[rightPage]?.tailLines ?? [])
            )
            leftBody = removingTailLines(seam.leftTailArtifacts, from: leftText)
        }

        var rightBody = rightRaw
        if rightPage.isPageBlob {
            let rightText = right.text ?? ""
            seam.rightHeadArtifacts = headLineArtifacts(
                in: rightText,
                neighborsAvailable: true,
                previousEdgeLines: leftPage.isPageBlob
                    ? edgeLines(.head, of: left.text ?? "")
                    : (pageEdges[leftPage]?.headLines ?? []),
                nextEdgeLines: neighborEdgeLines(of: rightPage, edge: .head, side: .next)
            )
            rightBody = removingHeadLines(seam.rightHeadArtifacts, from: rightText)
        }

        seam.merge = try computeMerge(
            leftBody: leftBody,
            rightBody: rightBody,
            rightLocator: right.locator
        )
        return seam
    }

    /// Looks for a sentence spanning the seam between the two page bodies, by
    /// joining the tail of the left body with the head of the right body and
    /// re-tokenizing the result into sentences.
    private func computeMerge(leftBody: String, rightBody: String, rightLocator: Locator) throws -> Seam.Merge? {
        let a = String(trimmingTail(leftBody).suffix(seamChunkLength))
        let bFull = trimmingHead(rightBody)
        let b = String(bFull.prefix(seamChunkLength))
        guard !a.isEmpty, !b.isEmpty, !endsWithTerminalPunctuation(a) else {
            return nil
        }

        // A word cut by a hyphen at the page break is joined directly,
        // dropping the hyphen; otherwise the halves are joined with a space.
        let hyphens: Set<Character> = ["-", "\u{2010}", "\u{00AD}"]
        let dehyphenate = a.last.map { hyphens.contains($0) } == true
            && b.first?.isLowercase == true
        let aSpoken = dehyphenate ? String(a.dropLast()) : a
        let joined = dehyphenate ? aSpoken + b : aSpoken + " " + b
        let seamIndex = joined.index(joined.startIndex, offsetBy: aSpoken.count)

        let tokenize = textTokenizer()
        guard let token = try tokenize(joined)
            .first(where: { $0.lowerBound < seamIndex && $0.upperBound > seamIndex })
        else {
            return nil
        }

        let partALength = joined.distance(from: token.lowerBound, to: seamIndex)
        let bStart = dehyphenate ? seamIndex : joined.index(after: seamIndex)
        let partBLength = joined.distance(from: max(bStart, token.lowerBound), to: token.upperBound)
        guard partALength > 0, partBLength > 0 else {
            return nil
        }

        // A left body which is entirely mid-sentence belongs to a page in the
        // middle of a sentence spanning 3+ pages: the sentence didn't start
        // there, so this is not its first seam and we don't merge. (A
        // sentence is only stitched across the seam of the page it starts
        // on.)
        let fullLeftBody = trimmed(leftBody)
        if token.lowerBound == joined.startIndex,
           fullLeftBody.count <= seamChunkLength,
           fullLeftBody.first(where: \.isLetter)?.isLowercase == true
        {
            return nil
        }

        let partAOnPage = String(a.suffix(partALength + (dehyphenate ? 1 : 0)))
        let partBOnPage = String(bFull.prefix(partBLength))
        let afterContext = String(trimmingHead(String(bFull.dropFirst(partBLength))).prefix(contextSnippetLength))

        return Seam.Merge(
            partAOnPage: partAOnPage,
            partASpoken: dehyphenate ? String(partAOnPage.dropLast()) : partAOnPage,
            partBOnPage: partBOnPage,
            partBSpoken: dehyphenate ? partBOnPage : " " + partBOnPage,
            joiner: dehyphenate ? .direct : .space,
            rightLocator: rightLocator,
            partBAfterContext: Optional(afterContext).takeIf { !$0.isEmpty }
        )
    }

    private var _textTokenizer: TextTokenizer?
    private func textTokenizer() -> TextTokenizer {
        if let tokenizer = _textTokenizer {
            return tokenizer
        }
        let tokenizer = textTokenizerFactory(language)
        _textTokenizer = tokenizer
        return tokenizer
    }

    // MARK: - Artifact detection

    /// Detects the artifact lines at the tail of a page blob, walking up from
    /// the last non-blank line.
    private func tailLineArtifacts(
        in text: String,
        neighborsAvailable: Bool,
        previousEdgeLines: [String],
        nextEdgeLines: [String]
    ) -> [Seam.Artifact] {
        var lines = text.components(separatedBy: "\n")
        var artifacts: [Seam.Artifact] = []
        while artifacts.count < maxArtifactsPerEdge {
            guard
                let index = lines.lastIndex(where: { !trimmed($0).isEmpty }),
                let kind = detectArtifact(
                    text: lines[index],
                    edge: .tail,
                    scope: .line,
                    neighborsAvailable: neighborsAvailable,
                    previousEdgeLines: previousEdgeLines,
                    nextEdgeLines: nextEdgeLines
                )
            else {
                break
            }
            artifacts.append(Seam.Artifact(text: trimmed(lines[index]), kind: kind))
            lines.removeSubrange(index...)
        }
        return artifacts.reversed()
    }

    /// Detects the artifact lines at the head of a page blob.
    private func headLineArtifacts(
        in text: String,
        neighborsAvailable: Bool,
        previousEdgeLines: [String],
        nextEdgeLines: [String]
    ) -> [Seam.Artifact] {
        var lines = text.components(separatedBy: "\n")
        var artifacts: [Seam.Artifact] = []
        while artifacts.count < maxArtifactsPerEdge {
            guard
                let index = lines.firstIndex(where: { !trimmed($0).isEmpty }),
                let kind = detectArtifact(
                    text: lines[index],
                    edge: .head,
                    scope: .line,
                    neighborsAvailable: neighborsAvailable,
                    previousEdgeLines: previousEdgeLines,
                    nextEdgeLines: nextEdgeLines
                )
            else {
                break
            }
            artifacts.append(Seam.Artifact(text: trimmed(lines[index]), kind: kind))
            lines.removeSubrange(...index)
        }
        return artifacts
    }

    /// Removes the given artifact lines from the tail of `text`.
    private func removingTailLines(_ artifacts: [Seam.Artifact], from text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        for artifact in artifacts.reversed() {
            guard
                let index = lines.lastIndex(where: { !trimmed($0).isEmpty }),
                trimmed(lines[index]) == artifact.text
            else {
                log(.warning, "Artifact lines do not match the page text")
                break
            }
            lines.removeSubrange(index...)
        }
        return lines.joined(separator: "\n")
    }

    /// Removes the given artifact lines from the head of `text`.
    private func removingHeadLines(_ artifacts: [Seam.Artifact], from text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        for artifact in artifacts {
            guard
                let index = lines.firstIndex(where: { !trimmed($0).isEmpty }),
                trimmed(lines[index]) == artifact.text
            else {
                log(.warning, "Artifact lines do not match the page text")
                break
            }
            lines.removeSubrange(...index)
        }
        return lines.joined(separator: "\n")
    }

    /// Detects whether a standalone FXL element at a page edge is an
    /// artifact (e.g. a page number as its own element).
    private func wholeElementArtifactKind(
        of element: TextContentElement,
        page: PageIdentity,
        edges: [PageArtifactCandidate.Edge] = [.head, .tail]
    ) -> PageArtifactKind? {
        guard let text = element.text else {
            return nil
        }
        for edge in edges {
            if let kind = detectArtifact(
                text: text,
                edge: edge,
                scope: .element,
                neighborsAvailable: true,
                previousEdgeLines: neighborEdgeLines(of: page, edge: edge, side: .previous),
                nextEdgeLines: neighborEdgeLines(of: page, edge: edge, side: .next)
            ) {
                return kind
            }
        }
        return nil
    }

    /// Runs the artifact detectors on a candidate, pairing it with each of
    /// the known neighboring edge lines.
    private func detectArtifact(
        text: String,
        edge: PageArtifactCandidate.Edge,
        scope: PageArtifactCandidate.Scope,
        neighborsAvailable: Bool,
        previousEdgeLines: [String],
        nextEdgeLines: [String]
    ) -> PageArtifactKind? {
        let candidateText = trimmed(text)
        guard !candidateText.isEmpty else {
            return nil
        }

        for detector in artifactDetectors {
            if detector.requiresNeighbors {
                guard neighborsAvailable else {
                    continue
                }
                let previous: [String?] = previousEdgeLines.isEmpty ? [nil] : previousEdgeLines
                let next: [String?] = nextEdgeLines.isEmpty ? [nil] : nextEdgeLines
                for previousLine in previous {
                    for nextLine in next {
                        guard previousLine != nil || nextLine != nil else {
                            continue
                        }
                        if let kind = detector.detectArtifact(in: PageArtifactCandidate(
                            text: candidateText,
                            edge: edge,
                            scope: scope,
                            previousPageEdgeText: previousLine,
                            nextPageEdgeText: nextLine
                        )) {
                            return kind
                        }
                    }
                }
            } else if let kind = detector.detectArtifact(in: PageArtifactCandidate(
                text: candidateText,
                edge: edge,
                scope: scope,
                previousPageEdgeText: previousEdgeLines.first,
                nextPageEdgeText: nextEdgeLines.first
            )) {
                return kind
            }
        }
        return nil
    }

    // MARK: - Page edge memory

    /// Edge text of the pages observed so far, used by neighbor-requiring
    /// artifact detectors (running headers). Needed because a page's first
    /// element may be long gone from the buffer by the time the next page's
    /// header must be compared against it.
    private struct PageEdges {
        var headLines: [String] = []
        var tailLines: [String] = []
    }

    private enum PageSide {
        case previous, next
    }

    private var pageEdges: [PageIdentity: PageEdges] = [:]

    /// Identities of the observed pages, in reading order, used to resolve a
    /// page's previous/next neighbor.
    private var observedPages: [PageIdentity] = []

    private func recordBlobEdges(of element: TextContentElement, page: PageIdentity) {
        guard pageEdges[page] == nil else {
            return
        }
        let text = element.text ?? ""
        pageEdges[page] = PageEdges(
            headLines: edgeLines(.head, of: text),
            tailLines: edgeLines(.tail, of: text)
        )
        registerObservedPage(page)
    }

    private func recordEdge(_ edge: PageArtifactCandidate.Edge, of page: PageIdentity, element: TextContentElement) {
        let text = trimmed(element.text ?? "")
        guard !text.isEmpty else {
            return
        }
        var edges = pageEdges[page] ?? PageEdges()
        switch edge {
        case .head:
            guard edges.headLines.isEmpty else { return }
            edges.headLines = [text]
        case .tail:
            guard edges.tailLines.isEmpty else { return }
            edges.tailLines = [text]
        }
        pageEdges[page] = edges
        registerObservedPage(page)
    }

    /// Records that `left`'s page immediately precedes `right`'s in reading
    /// order.
    private func recordAdjacency(left: PageIdentity, right: PageIdentity) {
        let leftIndex = observedPages.firstIndex(of: left)
        let rightIndex = observedPages.firstIndex(of: right)
        switch (leftIndex, rightIndex) {
        case (.some, .some), (nil, nil):
            registerObservedPage(left)
            registerObservedPage(right)
        case let (.some(i), nil):
            observedPages.insert(right, at: i + 1)
        case let (nil, .some(j)):
            observedPages.insert(left, at: j)
        }
        trimObservedPages()
    }

    private func registerObservedPage(_ page: PageIdentity) {
        guard !observedPages.contains(page) else {
            return
        }
        observedPages.append(page)
        trimObservedPages()
    }

    private func trimObservedPages() {
        while observedPages.count > 16 {
            let removed = observedPages.removeFirst()
            pageEdges.removeValue(forKey: removed)
        }
    }

    private func neighborEdgeLines(of page: PageIdentity, edge: PageArtifactCandidate.Edge, side: PageSide) -> [String] {
        guard let index = observedPages.firstIndex(of: page) else {
            return []
        }
        let neighborIndex = side == .previous ? index - 1 : index + 1
        guard observedPages.indices.contains(neighborIndex), let edges = pageEdges[observedPages[neighborIndex]] else {
            return []
        }
        return edge == .head ? edges.headLines : edges.tailLines
    }

    /// Returns the first or last few non-blank trimmed lines of a page text.
    private func edgeLines(_ edge: PageArtifactCandidate.Edge, of text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
            .map { trimmed($0) }
            .filter { !$0.isEmpty }
        switch edge {
        case .head:
            return Array(lines.prefix(maxArtifactsPerEdge))
        case .tail:
            return Array(lines.suffix(maxArtifactsPerEdge))
        }
    }

    // MARK: - Text helpers

    private func trimmed(_ string: String) -> String {
        string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func trimmingHead(_ string: String) -> String {
        String(string.drop(while: \.isWhitespace))
    }

    private func trimmingTail(_ string: String) -> String {
        var string = string
        while let last = string.last, last.isWhitespace {
            string.removeLast()
        }
        return string
    }

    /// Returns whether the text ends a sentence, i.e. finishes with terminal
    /// punctuation, possibly followed by closing quotes or brackets.
    private func endsWithTerminalPunctuation(_ text: String) -> Bool {
        let closers: Set<Character> = ["\"", "'", "”", "’", "»", "›", ")", "]", "}"]
        let terminals: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
        var text = Substring(trimmed(text))
        while let last = text.last, closers.contains(last) {
            text = text.dropLast()
        }
        guard let last = text.last else {
            return false
        }
        return terminals.contains(last)
    }
}
