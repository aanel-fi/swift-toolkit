//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import ReadiumShared

/// What the EPUB navigator needs in order to render a rendition.
///
/// This is deliberately narrower than ``Publication``: a rendition is a
/// sequence of resources plus enough manifest metadata to lay them out. The
/// navigator declares this port and every source adapts to it, instead of the
/// navigator reaching into the ``Publication`` aggregate.
///
/// ``Publication`` conforms to it (see below), but so can any other backing
/// store, e.g. a non-linear resource displayed on its own, or a rendition
/// served by a different toolkit.
public protocol EPUBRenditionSource: Sendable {
    /// Resources to render, in reading order.
    var readingOrder: [Link] { get }

    /// Metadata describing how to lay out the rendition.
    ///
    /// The navigator only reads `language`, `readingProgression` and `layout`.
    var metadata: Metadata { get }

    /// The URL where the rendition is served, when it is already reachable
    /// over HTTP. When nil, the navigator serves the resources itself.
    var baseURL: HTTPURL? { get }

    /// Finds the first ``Link`` with the given `href` in the rendition.
    func linkWithHREF<T: URLConvertible>(_ href: T) -> Link?

    /// Returns the resource at the given `href`, or nil when the rendition
    /// does not contain it.
    func resource<T: URLConvertible>(at href: T) -> (any Resource)?
}

public extension EPUBRenditionSource {
    /// Historically, we used to have "absolute" HREFs in the manifest:
    ///  - starting with a `/` for packaged publications.
    ///  - resolved to the `self` link for remote publications.
    ///
    /// We removed the normalization and now use relative HREFs everywhere, but
    /// we still need to support the locators created with the old absolute
    /// HREFs.
    func normalizeLocator(_ locator: Locator) -> Locator {
        var locator = locator

        if let baseURL = baseURL { // Remote rendition
            // Check that the locator HREF relative to `baseURL` exists in the
            // manifest.
            if let relativeHREF = baseURL.relativize(locator.href) {
                locator.href = linkWithHREF(relativeHREF)?.url()
                    ?? relativeHREF.anyURL
            }

        } else { // Packaged rendition
            if let href = AnyURL(string: locator.href.string.removingPrefix("/")) {
                locator.href = href
            }
        }

        return locator
    }

    /// Converts a ``Link`` into a ``Locator`` pointing at the start of the
    /// resource it targets.
    ///
    /// Derived from the manifest, mirroring ``DefaultLocatorService``. Renditions
    /// backed by a positions list can do better; the navigator prefers
    /// ``EPUBNavigatorViewController/Configuration/locate`` when one is set.
    func locate(_ link: Link) -> Locator? {
        let originalHREF = link.url()
        let fragment = originalHREF.fragment
        let href = originalHREF.removingFragment()

        guard
            let resourceLink = linkWithHREF(href),
            let mediaType = resourceLink.mediaType
        else {
            return nil
        }

        return Locator(
            href: href,
            mediaType: mediaType,
            title: resourceLink.title ?? link.title,
            locations: Locator.Locations(
                fragments: Array(ofNotNil: fragment),
                progression: (fragment == nil) ? 0.0 : nil
            )
        )
    }
}

/// Optional capability: a rendition able to provide a list of discrete
/// positions, grouped by reading order index.
///
/// Kept separate from ``EPUBRenditionSource`` because positions are only
/// meaningful for a rendition covering a publication's own reading order.
///
/// - Note: named `positionsByReadingOrder()` rather than `positions()` to
///   match ``PositionsService`` and avoid overloading on return type alone.
public protocol PositionsSource: Sendable {
    /// List of all the positions, grouped by reading order index.
    func positionsByReadingOrder() async -> ReadResult<[[Locator]]>
}

// MARK: - Publication adapter

extension Publication: EPUBRenditionSource {
    /// Forwards to ``Publication/get(_:)`` to preserve the
    /// services-then-container lookup fallback.
    public func resource<T: URLConvertible>(at href: T) -> (any Resource)? {
        get(href)
    }
}

extension Publication: PositionsSource {}
