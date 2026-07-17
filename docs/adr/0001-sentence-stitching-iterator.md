# ADR 0001 – Sentence stitching as a `ContentIterator` decorator

## Status

Accepted

## Context

TTS is unusable with PDF and EPUB FXL publications: sentences cut between pages are spoken as broken fragments, and stray page text (page numbers, running headers) is pasted mid-sentence.

The root cause is structural. Each PDF page becomes one single-segment `TextContentElement`, each FXL page is a separate resource, and sentence tokenization (`makeTextContentTokenizer`) is a pure per-element function which can never see across element boundaries.

## Decision

Implement the fix as a `ContentIterator` decorator (`SentenceStitchingContentIterator`) wrapping the composite `PublicationContentIterator`, rather than as a tokenizer.

* `Tokenizer` is a pure per-element function. Splitting fits there, but stitching cannot: it needs cross-element state (a lookahead window over the neighboring pages), which is exactly what an iterator can hold.
* The wrap point is above the composite iterator, not inside resource iterators, so PDF same-`href` page seams and FXL cross-`href` seams flow through one seam handler.

The decorator is applied automatically by `DefaultContentService`, for fixed-layout publications only (`metadata.layout == .fixed` or conforming to the PDF profile). Reflowable publications don't cut sentences between resources in a way visible to users, and their elements are semantic blocks rather than pages.

## Consequences

* All consumers of the `Content` API (TTS, search, extraction) see stitched elements without opting in.
* The stitched form of an element is a pure function of its raw neighbors, so forward and backward iteration produce consistent elements.
* Known limitations, accepted: a sentence spanning 3+ pages is merged across its first seam only; a page ending on an abbreviation ("…said Mr.") is not merged; the activation gate uses the publication-wide layout, ignoring per-spine-item `rendition:layout` overrides in mixed EPUBs.
