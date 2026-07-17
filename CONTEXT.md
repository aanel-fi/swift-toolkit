# Domain glossary

Terms used throughout the toolkit's code and documentation, in particular for the fixed-layout sentence stitching feature.

* **Seam** – the boundary between two adjacent fixed-layout pages in the content stream. A PDF page boundary is a seam between two `page=` fragments of the same resource; an EPUB FXL page boundary is a seam between two resources.
* **Stitching** – re-balancing text across a seam so that no `ContentElement` ends mid-sentence. The continuation of a sentence cut by a page break is moved onto the element where the sentence starts. See `SentenceStitchingContentIterator`.
* **Page Artifact** – page-boundary noise that is not part of the reading flow: a page number, a running header or footer. Detected by `PageArtifactDetector` implementations and marked with the `pageArtifact` content attribute (kept for search, skipped by TTS).
* **Continuation** – a `TextContentElement.Segment` marked with the `continued` attribute, carrying the cross-page remainder of the sentence started in the immediately preceding segment. Its locator targets its own page, so it stays renderable there.
* **Page Identity** – what distinguishes one fixed-layout page from another in the content stream: the resource `href` plus the `page=` locator fragment. Elements sharing both belong to the same page and are never stitched together.
