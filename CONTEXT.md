# Readium Swift Toolkit

A toolkit for building reading apps for ebooks, audiobooks and comics on Apple platforms: shared models, publication parsing, rendering navigators, OPDS and LCP DRM.

## Language

**Publication**:
An opened, ready-to-render digital book: a Manifest plus the services and resources needed to consume it.
_Avoid_: Book, ebook (as API terms)

**Manifest**:
The structural description of a Publication (metadata, reading order, resources, links), following the Readium Web Publication Manifest model.

**Link**:
A pointer from a Manifest to a resource or related document, carrying an Href, media type and properties.

**Href**:
A possibly-templated reference to a resource, resolved against the Publication's base URL.

**Locator**:
A precise, immutable location inside a Publication (resource, progression, text context), usable across sessions and devices.
_Avoid_: Position (which is a specific numbered Locator), bookmark (an app-level concept built on Locators)

**Resource**:
A single readable blob of content (bytes with lazy, possibly random-access reads), independent of where it comes from.
_Avoid_: File, stream

**Container**:
A collection of Resources addressed by URL, such as an EPUB archive or an exploded directory.
_Avoid_: Archive (which is specifically a zip-like packaged Container)

**Asset**:
A publication file or package as retrieved from storage or network, before parsing: a Resource or Container tagged with its sniffed Format.

**Format**:
The identified nature of an Asset (e.g. EPUB, PDF, RWPM), determined by sniffing.

**Sniffing**:
The process of identifying an Asset's Format from hints (file extension, media type) and content inspection.

**Streamer**:
The component that parses an Asset into a Publication.
_Avoid_: Parser (reserved for the per-format PublicationParser implementations)

**Navigator**:
The component rendering a Publication and tracking the reading location.
