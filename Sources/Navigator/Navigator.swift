//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import ReadiumInternal
import ReadiumShared
import SafariServices

public protocol Navigator: AnyObject {
    /// Publication being rendered.
    var publication: Publication { get }

    /// Current position in the publication.
    /// Can be used to save a bookmark to the current position.
    var currentLocation: Locator? { get }

    /// Moves to the position in the publication correponding to the given
    /// `Locator`.
    ///
    /// - Returns: Whether the navigator is able to move to the locator. The
    ///   completion block is only called if true was returned.
    @discardableResult
    func go(to locator: Locator, options: NavigatorGoOptions) async -> Bool

    // Moves to the position in the publication targeted by the given link.

    /// - Returns: Whether the navigator is able to move to the locator. The
    ///   completion block is only called if true was returned.
    @discardableResult
    func go(to link: Link, options: NavigatorGoOptions) async -> Bool

    /// Moves to the next content portion (eg. page or audiobook resource) in
    /// the reading progression direction.
    ///
    /// - Returns: Whether the navigator is able to move to the next content
    ///   portion. The completion block is only called if true was returned.
    @discardableResult
    func goForward(options: NavigatorGoOptions) async -> Bool

    /// Moves to the previous content portion (eg. page or audiobook resource)
    /// in the reading progression direction.
    ///
    /// - Returns: Whether the navigator is able to move to the previous content
    ///   portion. The completion block is only called if true was returned.
    @discardableResult
    func goBackward(options: NavigatorGoOptions) async -> Bool
}

public struct NavigatorGoOptions: Hashable {
    /// Indicates whether the move should be animated when possible.
    public var animated: Bool = false

    /// Extension point for navigator implementations.
    public var otherOptions: [String: JSONValue]

    public init(animated: Bool = false, otherOptions: [String: JSONValue] = [:]) {
        self.animated = animated
        self.otherOptions = .init(otherOptions)
    }

    public static var none: NavigatorGoOptions {
        NavigatorGoOptions()
    }

    /// Convenience helper for options that contain only animated: true.
    public static var animated: NavigatorGoOptions {
        NavigatorGoOptions(animated: true)
    }
}

public extension Navigator {
    @discardableResult
    func go(to locator: Locator, options: NavigatorGoOptions = NavigatorGoOptions()) async -> Bool {
        await go(to: locator, options: options)
    }

    @discardableResult
    func go(to link: Link, options: NavigatorGoOptions = NavigatorGoOptions()) async -> Bool {
        await go(to: link, options: options)
    }

    @discardableResult
    func goForward(options: NavigatorGoOptions = NavigatorGoOptions()) async -> Bool {
        await goForward(options: options)
    }

    @discardableResult
    func goBackward(options: NavigatorGoOptions = NavigatorGoOptions()) async -> Bool {
        await goBackward(options: options)
    }
}

/// aanel: why a location change is being reported.
///
/// Two causes are labelled because they are the two a HOST cannot see. Both
/// are driven from inside the navigator, so a host classifying by exclusion —
/// "everything else is the user" — calls them user scrolls and detaches
/// read-along.
///
/// `unspecified` is the default for every unlabelled path, so omitting a label
/// degrades to no-information rather than asserting a wrong one. **Consumers
/// must read it as "no information", never as "the user."**
///
/// Reaches a consumer two ways, both fed from the same value:
/// `NavigatorDelegate.navigator(_:locationDidChange:aanelCause:)` for anything
/// that owns a delegate conformance, and
/// `EPUBNavigatorViewController.aanelLastNotifiedLocationCause` for anything
/// reached synchronously from that call — see that property for the caveat.
///
/// Only `EPUBNavigatorViewController` in continuous scroll mode ever reports a
/// cause other than `.unspecified`.
public enum AanelLocationCause: Sendable {
    /// Layout resolving under a reader who did not ask for it. Emitted by
    /// `ContinuousPaginationView` from two places: `updatePageHeight`, which
    /// runs whenever a page reports a real height — every WebView finishing
    /// its load, including at idle minutes after open while chapters preload —
    /// and the completion of a preload window in `loadPages`.
    ///
    /// **A settle is not evidence the reader was still.** Scrolling into a new
    /// spread starts exactly this work, so a `.settle` can be emitted *during*
    /// a finger scroll. It says this particular report came from layout rather
    /// than from a gesture; it says nothing about what the finger was doing.
    case settle
    /// The navigator re-established a reading position it captured itself,
    /// after its own spreads were rebuilt. `EPUBNavigatorViewController`
    /// passes `navigateToLocationAfterReload: true` unconditionally, and this
    /// labels every one of those reloads — the host issues nothing and
    /// observes no landing in any of them:
    ///
    /// - the initial publication open (`initialize()`);
    /// - any pagination-view invalidation, which covers the Sivut<->Rulla
    ///   container swap AND a preference-driven reflow such as a font-size
    ///   change, where the container is kept and only the spreads rebuild;
    /// - a reload deferred while backgrounded, applied on `didBecomeActive`
    ///   (e.g. a rotation);
    /// - recovery from a WebView process termination.
    ///
    /// So `.restore` is NOT "the mode switch". It is "the navigator put the
    /// reader back where they were after rebuilding its own spreads".
    case restore
    /// Everything else, including every path this fork does not label.
    case unspecified
}

@MainActor public protocol NavigatorDelegate: AnyObject {
    /// Called when the current position in the publication changed. You should save the locator here to restore the
    /// last read page.
    func navigator(_ navigator: Navigator, locationDidChange locator: Locator)

    /// aanel: the same notification, carrying the navigator's own answer to
    /// "why did this happen" — see `AanelLocationCause`.
    ///
    /// Every navigator in this module reports through this method, and the
    /// default implementation forwards to the unlabelled one above, so an
    /// existing conformer needs no change. Routing the non-EPUB navigators
    /// through it too is deliberate and is the reason they appear in the aanel
    /// delta at all: without it, a conformer that implemented ONLY this method
    /// would silently stop receiving audio position changes.
    func navigator(_ navigator: Navigator, locationDidChange locator: Locator, aanelCause: AanelLocationCause)

    /// Called when the navigator jumps to an explicit location, which might break the linear reading progression.
    ///
    /// For example, it is called when clicking on internal links or programmatically calling `go()`, but not when
    /// turning pages.
    ///
    /// You can use this callback to implement a navigation history by differentiating between continuous and
    /// discontinuous moves.
    func navigator(_ navigator: Navigator, didJumpTo locator: Locator)

    /// Called when an error must be reported to the user.
    func navigator(_ navigator: Navigator, presentError error: NavigatorError)

    /// Called when the user tapped an external URL. The default implementation opens the URL with the default browser.
    func navigator(_ navigator: Navigator, presentExternalURL url: URL)

    /// Called when the user taps on a link referring to a note.
    ///
    /// Return `true` to navigate to the note, or `false` if you intend to present the
    /// note yourself, using its `content`. `link.type` contains information about the
    /// format of `content` and `referrer`, such as `text/html`.
    func navigator(_ navigator: Navigator, shouldNavigateToNoteAt link: Link, content: String, referrer: String?) -> Bool

    /// Called when an error occurs while attempting to load a resource.
    func navigator(_ navigator: Navigator, didFailToLoadResourceAt href: RelativeURL, withError error: ReadError)
}

public extension NavigatorDelegate {
    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {}

    func navigator(_ navigator: Navigator, locationDidChange locator: Locator, aanelCause: AanelLocationCause) {
        self.navigator(navigator, locationDidChange: locator)
    }

    func navigator(_ navigator: Navigator, didJumpTo locator: Locator) {}

    func navigator(_ navigator: Navigator, presentExternalURL url: URL) {
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }

    func navigator(_ navigator: Navigator, shouldNavigateToNoteAt link: Link, content: String, referrer: String?) -> Bool {
        true
    }

    func navigator(_ navigator: Navigator, didFailToLoadResourceAt href: RelativeURL, withError error: ReadError) {}
}

public enum NavigatorError: Error {
    /// The user tried to copy the text selection but the DRM License doesn't allow it.
    case copyForbidden
}
