//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import ReadiumInternal
import ReadiumShared
import UIKit
import WebKit

/// A view rendering a spread of resources with a reflowable layout.
final class EPUBReflowableSpreadView: EPUBSpreadView {
    private var topConstraint: NSLayoutConstraint!
    private var bottomConstraint: NSLayoutConstraint!
    private var webViewHeightConstraint: NSLayoutConstraint!
    private var contentInsets: UIEdgeInsets = .zero
    private var measuredDocumentHeight: CGFloat?
    private var documentHeightTask: Task<Void, Never>?

    private static let reflowableScript = loadScript(named: "readium-reflowable")
    private static let continuousScript = """
        (function () {
          if (window.readiumContinuous) {
            return;
          }

          function escapeCssIdentifier(value) {
            if (window.CSS && typeof window.CSS.escape === "function") {
              return window.CSS.escape(value);
            }
            return String(value).replace(/([^a-zA-Z0-9_-])/g, "\\\\$1");
          }

          function cssSelectorForElement(element) {
            if (!element || element.nodeType !== Node.ELEMENT_NODE) {
              return "body";
            }

            if (element.id) {
              return "#" + escapeCssIdentifier(element.id);
            }

            var segments = [];
            var current = element;
            while (current && current.nodeType === Node.ELEMENT_NODE && current !== document.documentElement) {
              var selector = current.nodeName.toLowerCase();
              if (current.id) {
                selector += "#" + escapeCssIdentifier(current.id);
                segments.unshift(selector);
                break;
              }

              var position = 1;
              var sibling = current.previousElementSibling;
              while (sibling) {
                if (sibling.nodeName === current.nodeName) {
                  position += 1;
                }
                sibling = sibling.previousElementSibling;
              }

              selector += ":nth-of-type(" + position + ")";
              segments.unshift(selector);
              current = current.parentElement;
            }

            if (segments.length === 0) {
              return "body";
            }
            return segments.join(" > ");
          }

          function makeRectJSON(rect) {
            return {
              x: rect.x,
              y: rect.y,
              width: rect.width,
              height: rect.height,
              top: rect.top,
              right: rect.right,
              bottom: rect.bottom,
              left: rect.left,
            };
          }

          function rangeForTextNormalized(searchRoot, target, before, after, nearY) {
            var walker = document.createTreeWalker(searchRoot, NodeFilter.SHOW_TEXT, null);
            var nodes = [];
            var total = 0;
            var node;
            while ((node = walker.nextNode())) {
              var raw = node.textContent || "";
              if (!raw) { continue; }
              nodes.push({ node: node, start: total, raw: raw });
              total += raw.length;
            }
            if (nodes.length === 0) { return null; }
            var full = "";
            for (var i = 0; i < nodes.length; i += 1) { full += nodes[i].raw; }
            var norm = "";
            var map = [];
            var lastSpace = true;
            for (var j = 0; j < full.length; j += 1) {
              var ch = full[j];
              if (ch === "\\u00AD") { continue; }
              if (/[\\u2010-\\u2015\\u2212]/.test(ch)) { ch = "-"; }
              if (/\\s/.test(ch)) {
                if (lastSpace) { continue; }
                norm += " ";
                map.push(j);
                lastSpace = true;
              } else {
                norm += ch;
                map.push(j);
                lastSpace = false;
              }
            }
            function normStr(s) {
              return String(s || "")
                .replace(/\\u00AD/g, "")
                .replace(/[\\u2010-\\u2015\\u2212]/g, "-")
                .replace(/\\s+/g, " ")
                .trim();
            }
            var h = normStr(target);
            if (!h) { return null; }
            var b = normStr(before);
            var a = normStr(after);
            function occTop(occIdx) {
              var rawIdx = map[occIdx];
              for (var q = 0; q < nodes.length; q += 1) {
                if (rawIdx < nodes[q].start + nodes[q].raw.length) {
                  var rr = document.createRange();
                  rr.selectNodeContents(nodes[q].node);
                  var rect = rectFromRange(rr);
                  var body = (document.body || document.documentElement).getBoundingClientRect();
                  return rect ? rect.top - body.top : 0;
                }
              }
              return 0;
            }
            var useNear = typeof nearY === "number";
            var best = -1;
            var bestScore = -1;
            var bestDist = Infinity;
            var idx = norm.indexOf(h);
            while (idx >= 0) {
              var score = 0;
              if (b && norm.slice(Math.max(0, idx - b.length - 2), idx).indexOf(b) >= 0) { score += 1; }
              if (a && norm.slice(idx + h.length, idx + h.length + a.length + 2).indexOf(a) >= 0) { score += 1; }
              var dist = useNear ? Math.abs(occTop(idx) - nearY) : 0;
              if (score > bestScore || (score === bestScore && useNear && dist < bestDist)) {
                bestScore = score;
                bestDist = dist;
                best = idx;
              }
              idx = norm.indexOf(h, idx + 1);
            }
            if (best < 0) { return null; }
            var rawStart = map[best];
            var rawEnd = map[best + h.length - 1] + 1;
            function locate(rawIndex) {
              for (var n = 0; n < nodes.length; n += 1) {
                var entry = nodes[n];
                if (rawIndex < entry.start + entry.raw.length) {
                  return { node: entry.node, offset: rawIndex - entry.start };
                }
              }
              var last = nodes[nodes.length - 1];
              return { node: last.node, offset: last.raw.length };
            }
            var startPos = locate(rawStart);
            var endPos = locate(rawEnd - 1);
            var range = document.createRange();
            range.setStart(startPos.node, startPos.offset);
            range.setEnd(endPos.node, endPos.offset + 1);
            return range;
          }

          function rangeForText(root, highlight, before, after, nearY) {
            var target = String(highlight || "").trim();
            if (!target) {
              return null;
            }

            var searchRoot = root || document.body;
            var walker = document.createTreeWalker(searchRoot, NodeFilter.SHOW_TEXT, {
              acceptNode: function (node) {
                return node.textContent && node.textContent.trim()
                  ? NodeFilter.FILTER_ACCEPT
                  : NodeFilter.FILTER_REJECT;
              },
            });

            var matches = [];
            var node;
            while ((node = walker.nextNode())) {
              var text = node.textContent || "";
              var index = text.indexOf(target);
              while (index >= 0) {
                matches.push({ node: node, index: index, text: text });
                index = text.indexOf(target, index + 1);
              }
            }

            if (matches.length === 0) {
              // aanel: exact per-node match failed (footnote superscripts,
              // typographic spaces, soft hyphens split or alter the text
              // nodes) — fall back to a normalized cross-node search so the
              // follow resolves everything the decoration engine can.
              return rangeForTextNormalized(searchRoot, target, before, after, nearY);
            }

            function score(match) {
              var points = 0;
              if (before && match.text.slice(Math.max(0, match.index - before.length), match.index).indexOf(before) >= 0) {
                points += 1;
              }
              if (after && match.text.slice(match.index + target.length, match.index + target.length + after.length).indexOf(after) >= 0) {
                points += 1;
              }
              return points;
            }

            // aanel: repeated phrases used to resolve to the FIRST occurrence
            // in the document on score ties, teleporting follows to identical
            // sentences pages away. With a nearY hint (the current reading
            // position), equal-scoring candidates prefer the nearest one.
            var docTop = documentTopOffset();
            function matchTop(m) {
              var r = document.createRange();
              r.setStart(m.node, m.index);
              r.setEnd(m.node, Math.min(m.index + target.length, (m.node.textContent || "").length));
              var rect = rectFromRange(r);
              return rect ? rect.top - docTop : 0;
            }
            var useNear = typeof nearY === "number" && matches.length > 1;
            var best = matches[0];
            var bestScore = score(best);
            var bestDist = useNear ? Math.abs(matchTop(best) - nearY) : 0;
            for (var i = 1; i < matches.length; i += 1) {
              var candidateScore = score(matches[i]);
              if (candidateScore < bestScore) { continue; }
              var dist = useNear ? Math.abs(matchTop(matches[i]) - nearY) : 0;
              if (candidateScore > bestScore || (useNear && dist < bestDist)) {
                best = matches[i];
                bestScore = candidateScore;
                bestDist = dist;
              }
            }

            var range = document.createRange();
            range.setStart(best.node, best.index);
            range.setEnd(best.node, best.index + target.length);
            return range;
          }

          function rectFromRange(range) {
            if (!range) {
              return null;
            }

            // aanel: the union box, not getClientRects()[0] — the first-line
            // fragment reports ~one line of height, which collapsed the
            // sentence-mass centring for multi-line sentences (top is the
            // same in both).
            return range.getBoundingClientRect();
          }

          function rectFromNode(node) {
            if (!node) {
              return null;
            }

            if (node.nodeType === Node.TEXT_NODE) {
              var textRange = document.createRange();
              textRange.selectNodeContents(node);
              return rectFromRange(textRange);
            }

            if (node.nodeType !== Node.ELEMENT_NODE) {
              return null;
            }

            var rects = node.getClientRects();
            if (rects && rects.length > 0) {
              return rects[0];
            }

            for (var i = 0; i < node.childNodes.length; i += 1) {
              var childRect = rectFromNode(node.childNodes[i]);
              if (childRect) {
                return childRect;
              }
            }

            return node.getBoundingClientRect();
          }

          function fragmentCandidates(fragment) {
            var value = String(fragment || "").trim();
            if (!value) {
              return [];
            }

            if (value.charAt(0) === "#") {
              value = value.slice(1);
            }

            var candidates = [value];
            try {
              var decoded = decodeURIComponent(value);
              if (decoded && candidates.indexOf(decoded) < 0) {
                candidates.push(decoded);
              }
            } catch (_) {}

            return candidates;
          }

          function elementFromFragment(fragment) {
            var candidates = fragmentCandidates(fragment);

            for (var i = 0; i < candidates.length; i += 1) {
              var element = document.getElementById(candidates[i]);
              if (element) {
                return element;
              }
            }

            for (var j = 0; j < candidates.length; j += 1) {
              var namedElements = document.getElementsByName(candidates[j]);
              for (var k = 0; k < namedElements.length; k += 1) {
                return namedElements[k];
              }
            }

            return null;
          }

          function findHeadingByTitle(title) {
            var target = String(title || "").trim();
            if (!target) {
              return null;
            }

            var headings = document.querySelectorAll("h1, h2, h3, h4, h5, h6");
            for (var i = 0; i < headings.length; i += 1) {
              var text = String(headings[i].textContent || "").trim();
              if (text === target) {
                return headings[i];
              }
            }

            for (var j = 0; j < headings.length; j += 1) {
              var partial = String(headings[j].textContent || "").trim();
              if (partial && partial.indexOf(target) >= 0) {
                return headings[j];
              }
            }

            return null;
          }

          function rectFromLocator(locator, nearY) {
            try {
              var locations = locator && locator.locations ? locator.locations : {};
              var text = locator && locator.text ? locator.text : {};
              var root = document.body;
              var element = null;

              if (locations.cssSelector) {
                element = document.querySelector(locations.cssSelector);
                if (element) {
                  root = element;
                }
              }

              if (!element && Array.isArray(locations.fragments)) {
                for (var i = 0; i < locations.fragments.length; i += 1) {
                  element = elementFromFragment(locations.fragments[i]);
                  if (element) {
                    break;
                  }
                }
              }

              if (element) {
                return rectFromNode(element);
              }

              if (locator && locator.title) {
                element = findHeadingByTitle(locator.title);
                if (element) {
                  return rectFromNode(element);
                }
              }

              if (text && text.highlight) {
                return rectFromRange(rangeForText(root, text.highlight, text.before, text.after, nearY));
              }
            } catch (_) {}

            return null;
          }

          function documentTopOffset() {
            var root = document.body || document.documentElement;
            if (!root) {
              return 0;
            }
            return root.getBoundingClientRect().top;
          }

          function shouldIgnoreElement(element) {
            var style = getComputedStyle(element);
            if (!style) {
              return false;
            }

            if (style.getPropertyValue("display") !== "block") {
              return true;
            }
            return style.getPropertyValue("opacity") === "0";
          }

          function isElementVisibleInRect(element, rect) {
            if (element === document.body || element === document.documentElement) {
              return true;
            }

            var elementRect = element.getBoundingClientRect();
            return (
              elementRect.bottom > rect.top &&
              elementRect.top < rect.bottom &&
              elementRect.right > rect.left &&
              elementRect.left < rect.right
            );
          }

          function findElementInRect(rootElement, rect) {
            for (var i = 0; i < rootElement.children.length; i += 1) {
              var child = rootElement.children[i];
              if (!shouldIgnoreElement(child) && isElementVisibleInRect(child, rect)) {
                return findElementInRect(child, rect);
              }
            }
            return rootElement;
          }

          function contentHeight() {
            var root = document.scrollingElement || document.documentElement || document.body;
            return Math.max(
              root ? root.scrollHeight : 0,
              root ? root.offsetHeight : 0,
              document.documentElement ? document.documentElement.scrollHeight : 0,
              document.documentElement ? document.documentElement.offsetHeight : 0,
              document.body ? document.body.scrollHeight : 0,
              document.body ? document.body.offsetHeight : 0
            );
          }

          window.readiumContinuous = {
            contentHeight: contentHeight,
            locatorRect: function (locator) {
              var rect = rectFromLocator(locator);
              return rect ? makeRectJSON(rect) : null;
            },
            locatorYOffset: function (locator, nearY) {
              var rect = rectFromLocator(locator, nearY);
              if (!rect) {
                return null;
              }
              return { top: rect.top - documentTopOffset(), height: rect.height || 0 };
            },
            findFirstVisibleLocatorInRect: function (rect) {
              var visibleRect = rect || {
                top: 0,
                left: 0,
                right: window.innerWidth,
                bottom: window.innerHeight,
              };
              var element = findElementInRect(document.body, visibleRect);
              return {
                href: "#",
                type: "application/xhtml+xml",
                locations: {
                  cssSelector: cssSelectorForElement(element),
                },
                text: {
                  highlight: (element.textContent || "").trim(),
                },
              };
            },
            notifyLayoutChange: function () {
              webkit.messageHandlers.continuousContentLayoutChanged.postMessage({});
            },
          };

          window.addEventListener("load", function () {
            var pendingNotification;
            function notify() {
              if (pendingNotification) {
                cancelAnimationFrame(pendingNotification);
              }
              pendingNotification = requestAnimationFrame(function () {
                window.readiumContinuous.notifyLayoutChange();
              });
            }

            notify();
            var observer = new ResizeObserver(notify);
            observer.observe(document.documentElement);
            observer.observe(document.body);
          });
        })();
        """

    private var isContinuousScrolling: Bool {
        scrollMode == .continuous
    }

    required init(
        viewModel: EPUBNavigatorViewModel,
        spread: EPUBSpread,
        scrollMode: ScrollMode,
        scripts: [WKUserScript],
        animatedLoad: Bool
    ) {
        super.init(
            viewModel: viewModel,
            spread: spread,
            scrollMode: scrollMode,
            scripts: [
                WKUserScript(source: Self.reflowableScript, injectionTime: .atDocumentStart, forMainFrameOnly: false),
                WKUserScript(source: Self.continuousScript, injectionTime: .atDocumentStart, forMainFrameOnly: false),
            ],
            animatedLoad: animatedLoad
        )
    }

    override func clear() {
        super.clear()

        documentHeightTask?.cancel()
        documentHeightTask = nil

        // aanel-settle-paginated: a spread view is recycled across resources,
        // so a pending emission would describe the document this view has just
        // stopped showing.
        aanelPageCentreWorkItem?.cancel()
        aanelPageCentreWorkItem = nil

        // Clean up go to continuations.
        for continuation in goToContinuations {
            continuation.resume()
        }
        goToContinuations.removeAll()

        scrollDidEnd()
    }

    override func setupWebView() {
        super.setupWebView()

        scrollView.bounces = false
        // Since iOS 16, the default value of alwaysBounceX seems to be true
        // for web views.
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false

        scrollView.isPagingEnabled = (scrollMode == .paginated)
        scrollView.isScrollEnabled = !isContinuousScrolling

        webView.translatesAutoresizingMaskIntoConstraints = false
        topConstraint = webView.topAnchor.constraint(equalTo: topAnchor)
        topConstraint.priority = .defaultHigh
        bottomConstraint = webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        bottomConstraint.priority = .defaultHigh
        webViewHeightConstraint = webView.heightAnchor.constraint(equalToConstant: 1)
        webViewHeightConstraint.priority = .required
        NSLayoutConstraint.activate([
            topConstraint, bottomConstraint,
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        updateContentInset()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateContentInset()
    }

    override func loadSpread() {
        guard spread.readingOrderIndices.count == 1 else {
            log(.error, "Only one document at a time can be displayed in a reflowable spread")
            return
        }
        let url = viewModel.url(to: spread.first.link)
        webView.load(URLRequest(url: url.url))
    }

    override func applySettings() {
        super.applySettings()

        scrollView.isPagingEnabled = (scrollMode == .paginated)
        scrollView.isScrollEnabled = !isContinuousScrolling

        updateContentInset()
        if isContinuousScrolling {
            scheduleDocumentHeightUpdate()
        }
    }

    // aanel: at INTERIOR chapter boundaries in continuous mode the content
    // insets are pure dead gap — a document edge only needs chrome clearance
    // when it is also an edge of the whole book. First spread keeps its top
    // inset, last keeps its bottom; everything else is zero.
    private var aanelContinuousInsets: UIEdgeInsets {
        guard isContinuousScrolling else { return contentInsets }
        let isFirst = spread.readingOrderIndices.lowerBound == 0
        let isLast = spread.readingOrderIndices.upperBound >= viewModel.readingOrder.count - 1
        return UIEdgeInsets(
            top: isFirst ? contentInsets.top : 0,
            left: 0,
            bottom: isLast ? contentInsets.bottom : 0,
            right: 0
        )
    }

    private func updateContentInset() {
        contentInsets = delegate?.spreadViewContentInset(self) ?? .zero

        if isContinuousScrolling {
            topConstraint.constant = aanelContinuousInsets.top
            bottomConstraint.isActive = false
            webViewHeightConstraint.isActive = true
            webViewHeightConstraint.constant = measuredDocumentHeight ?? estimatedDocumentHeight
            scrollView.contentInset = .zero
        } else if viewModel.scroll {
            topConstraint.constant = 0
            bottomConstraint.isActive = true
            webViewHeightConstraint.isActive = false
            bottomConstraint.constant = 0
            scrollView.contentInset = contentInsets

        } else {
            topConstraint.constant = contentInsets.top
            bottomConstraint.isActive = true
            webViewHeightConstraint.isActive = false
            bottomConstraint.constant = -contentInsets.bottom
            scrollView.contentInset = .zero
        }

        if isContinuousScrolling {
            onPreferredHeightChange?()
        }
    }

    override func convertPointToNavigatorSpace(_ point: CGPoint) -> CGPoint {
        var point = point
        if viewModel.scroll {
            if scrollView.contentOffset.x < 0 {
                point.x += abs(scrollView.contentOffset.x)
            }
            if scrollView.contentOffset.y < 0 {
                point.y += abs(scrollView.contentOffset.y)
            }
        }
        point.x += webView.frame.minX
        point.y += webView.frame.minY
        return point
    }

    override func convertRectToNavigatorSpace(_ rect: CGRect) -> CGRect {
        var rect = rect
        rect.origin = convertPointToNavigatorSpace(rect.origin)
        return rect
    }

    // MARK: - Location and progression

    override func progression(in index: ReadingOrder.Index) -> ClosedRange<Double> {
        guard
            spread.first.index == index,
            let progression = progression
        else {
            return 0 ... 0
        }
        return progression
    }

    override func progression(in index: ReadingOrder.Index, visibleRect: CGRect) -> ClosedRange<Double> {
        guard
            isContinuousScrolling,
            spread.first.index == index
        else {
            return progression(in: index)
        }

        let documentHeight = measuredDocumentHeight ?? 0
        guard documentHeight > 0 else {
            return 0 ... 0
        }

        let contentRect = CGRect(
            x: webView.frame.minX,
            y: webView.frame.minY,
            width: webView.frame.width,
            height: documentHeight
        )
        let intersection = visibleRect.intersection(contentRect)
        guard !intersection.isNull, !intersection.isEmpty else {
            return 0 ... 0
        }

        let first = min(max((intersection.minY - contentRect.minY) / documentHeight, 0), 1)
        let last = min(max((intersection.maxY - contentRect.minY) / documentHeight, first), 1)
        return first ... last
    }

    // aanel-settle-continuous-begin
    /// aanel: centre-locator emitter for continuous scroll mode. The OUTER
    /// ContinuousPaginationView owns the scrolling surface and calls this on
    /// the spread under the viewport centre; `point` is in this view's
    /// coordinate space. Hit-tests the webview for the sentence snippet at the
    /// centre and posts a serialized Locator on `noteName`
    /// (AanelRulla.scrollMove / .scrollSettle) — the same contract the
    /// per-spread emitter used before continuous scroll, so EPUBViewController
    /// and the JS selection-action bridge stay unchanged.
    /// Strict probe: emits ONLY if the point hits a real text node (caret
    /// hit-test) — no elementFromPoint fallback. In the inter-chapter gap
    /// (padding/divider/heading margins) elementFromPoint returns `body`,
    /// whose textContent head is the CHAPTER START — a misleading snippet that
    /// made early-chapter sentences unpickable at chapter edges. The
    /// completion reports whether an emission happened so the caller can fan
    /// out to the next probe point.
    func aanelEmitCentreLocator(
        atLocalPoint point: CGPoint,
        noteName: String,
        force: Bool,
        completion: @escaping (Bool) -> Void
    ) {
        let insetTop = aanelContinuousInsets.top
        let docHeight = measuredDocumentHeight ?? estimatedDocumentHeight
        guard docHeight > 0 else {
            completion(false)
            return
        }
        let progression = max(0.0, min(1.0, (point.y - insetTop) / docHeight))
        let link = spread.first.link
        var locations = Locator.Locations()
        locations.progression = progression
        let capturedLocations = locations
        // The webview is pinned at contentInsets.top with its own scroll
        // offset fixed at zero in continuous mode, so webview-local CSS px ==
        // spread-local points minus the top inset.
        let cx = Int(point.x)
        let cy = Int(max(0, point.y - insetTop))
        // Strict form: caret-on-text-node only, empty string otherwise. The
        // forced (last-resort) form keeps the old elementFromPoint fallback.
        let strictJS = "(function(){var r=document.caretRangeFromPoint?document.caretRangeFromPoint(\(cx),\(cy)):null;var n=r&&r.startContainer;if(n&&n.nodeType===3&&(n.textContent||'').trim()){var t=n.textContent||'';var o=r.startOffset||0;return t.substring(Math.max(0,o-30),o+80);}return '';})()"
        // Forced form: still caret-only. The old elementFromPoint fallback
        // returned `body` in the inter-chapter gap, whose textContent head is
        // the CHAPTER-OPENING text — a misleading snippet that dragged the
        // marker to the wrong chapter. An EMPTY snippet with the geometric
        // progression lets the JS matcher fall back cleanly instead.
        let forcedJS = strictJS
        webView.evaluateJavaScript(force ? forcedJS : strictJS) { result, _ in
            let snippet = ((result as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard force || !snippet.isEmpty else {
                completion(false)
                return
            }
            let locator = Locator(
                href: link.url(),
                mediaType: link.mediaType ?? .xhtml,
                locations: capturedLocations,
                text: Locator.Text(highlight: snippet)
            )
            guard let locatorJSON = try? locator.jsonString() else {
                completion(false)
                return
            }
            NotificationCenter.default.post(
                name: Notification.Name(noteName),
                object: nil,
                userInfo: ["locatorJSON": locatorJSON]
            )
            completion(true)
        }
    }
    // aanel-settle-continuous-end

    // aanel-settle-paginated-begin
    /// aanel: **page-centre** locator emitter for PAGINATED (Sivut) mode —
    /// Phase 2 step 2b of the reader native migration
    /// (`docs/architecture/reader-native-migration.md`, contract §3.2).
    ///
    /// The continuous (Rulla) emitter above answers "what is at the centre of
    /// the viewport" for a scrolling surface. A paginated surface had no such
    /// answer at all, and that absence is a shipped defect rather than a gap:
    /// the only position a paginated navigator exposes is `currentLocator`,
    /// whose progression is the page *start*. A reader flipping Sivut↔Rulla
    /// therefore had the two surfaces resolve the read-along resume marker from
    /// two different reference points — centre one way, page-top the other —
    /// and the legs do not cancel, so a round trip walked backwards by roughly
    /// two thirds of a viewport (`docs/requirements/reader-epub.md`, Known
    /// issues → mode-switch marker drift). It is unfixable above this layer
    /// because nothing above this layer can see the centre of a page.
    ///
    /// Deliberately mirrors the continuous emitter's contract rather than
    /// inventing a second one: a serialized `Locator` posted on a
    /// `NotificationCenter` name, carrying
    ///   * `locations.progression` — the **geometric centre** of the visible
    ///     page, always present, and
    ///   * `text.highlight` — the sentence snippet under the centre, when a
    ///     caret hit-test finds a real text node.
    /// The two are separate answers on purpose (contract §3.2): the centre may
    /// legitimately be an image, a heading or a paragraph gap, and a consumer
    /// that only had the snippet would go blind exactly there.
    ///
    /// **The whole probe is one `evaluateJavaScript` round trip, and both
    /// answers come from the same frame.** The Swift side already keeps a
    /// `progression` range for the page (`first ... last`, published by
    /// `readium-reflowable`'s scroll handler), and its midpoint is the same
    /// number — but it is refreshed asynchronously, so pairing a *stored*
    /// progression with a *live* hit-test can describe two different pages
    /// during a turn. Computing both in the page removes that skew by
    /// construction. It also mirrors upstream's own formula, including the RTL
    /// `abs(scrollX)` correction, so the centre cannot disagree with the
    /// navigator about which page it is on.
    ///
    /// The vertical fan-out repeats the continuous emitter's lesson: a bare
    /// centre probe lands in a paragraph gap or a margin often enough that the
    /// marker would blink out mid-chapter, so the probe walks outward from the
    /// centre (closest first) and takes the first real text node. The fan is
    /// vertical only — horizontally the centre of a single-column page is
    /// always inside the text block.
    static let pageCentreNotificationName = "AanelSivut.pageCentre"

    private var aanelPageCentreWorkItem: DispatchWorkItem?

    /// Coalesced request for a page-centre emission.
    ///
    /// Debounced rather than immediate because the two callers fire in bursts:
    /// a page turn produces a settle *and* a re-layout, and a mode-switch
    /// restore produces a load followed by its own `go(to:)`. Only the last
    /// one describes where the reader ended up.
    func aanelSchedulePageCentreEmit(delay: TimeInterval = 0.12) {
        guard scrollMode == .paginated else { return }
        aanelPageCentreWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.aanelEmitPageCentreLocator()
        }
        aanelPageCentreWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Caret-on-text-node only, exactly like the continuous probe's strict
    /// form: `elementFromPoint` returns `body` in a gap, whose `textContent`
    /// head is the *chapter opening* — a snippet that reads plausible and
    /// points at the wrong place. An empty snippet with a good progression is
    /// the honest answer, and the consumer falls back to it cleanly.
    private static let aanelPageCentreJS = """
    (function(){
      var root = document.scrollingElement;
      if (!root) { return ""; }
      var w = window.innerWidth, h = window.innerHeight;
      var total = root.scrollWidth;
      if (!(total > 0) || !(w > 0) || !(h > 0)) { return ""; }
      var x = window.scrollX;
      if (x < 0) { x = -x; }
      var p = (x + w / 2) / total;
      if (p < 0) { p = 0; }
      if (p > 1) { p = 1; }
      var s = "";
      if (document.caretRangeFromPoint) {
        var fr = [0, 0.06, -0.06, 0.12, -0.12, 0.19, -0.19, 0.27, -0.27, 0.35, -0.35];
        for (var i = 0; i < fr.length && !s; i++) {
          var y = h / 2 + fr[i] * h;
          if (y < 0 || y > h) { continue; }
          var r = document.caretRangeFromPoint(w / 2, y);
          var n = r && r.startContainer;
          if (n && n.nodeType === 3 && (n.textContent || "").trim()) {
            var t = n.textContent || "";
            var o = r.startOffset || 0;
            s = t.substring(Math.max(0, o - 30), o + 80);
          }
        }
      }
      return JSON.stringify({ s: s, p: p });
    })()
    """

    private func aanelEmitPageCentreLocator() {
        guard scrollMode == .paginated, isSpreadLoaded else { return }
        let link = spread.first.link
        webView.evaluateJavaScript(Self.aanelPageCentreJS) { result, _ in
            guard
                let json = result as? String,
                let data = json.data(using: .utf8),
                let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let progression = payload["p"] as? Double
            else {
                return
            }
            let snippet = ((payload["s"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var locations = Locator.Locations()
            locations.progression = min(max(progression, 0), 1)
            let locator = Locator(
                href: link.url(),
                mediaType: link.mediaType ?? .xhtml,
                locations: locations,
                // Absent, not empty: an empty highlight is a *value* the
                // consumer would have to special-case, and `Locator.Text`
                // already models "no text" as nil.
                text: snippet.isEmpty ? Locator.Text() : Locator.Text(highlight: snippet)
            )
            guard let locatorJSON = try? locator.jsonString() else { return }
            NotificationCenter.default.post(
                name: Notification.Name(EPUBReflowableSpreadView.pageCentreNotificationName),
                object: nil,
                userInfo: ["locatorJSON": locatorJSON]
            )
        }
    }
    // aanel-settle-paginated-end

    override func spreadDidLoad() async {
        let link = spread.first.link
        if let linkJSON = try? link.jsonString() {
            await evaluateScript("readium.link = \(linkJSON);")
        }
        // aanel-bodypad-begin: scroll-mode body padding so chapter
        // start/end clears the chrome edge-fade overlays.
        if viewModel.scroll {
            await evaluateScript("(function(){if(!document.body)return;document.body.style.setProperty(\"padding-top\",\"32px\",\"important\");document.body.style.setProperty(\"padding-bottom\",\"32px\",\"important\");})()")
        }
        // aanel-bodypad-end
        // aanel-divider-begin: scroll-mode full-bleed chapter hairline,
        // suppressed on the last resource (no trailing line at book end).
        if viewModel.scroll,
           spread.readingOrderIndices.upperBound < viewModel.readingOrder.count - 1 {
            await evaluateScript("(function(){if(!document.body)return;if(document.getElementById(\"aanel-divider-style\"))return;var s=document.createElement(\"style\");s.id=\"aanel-divider-style\";s.textContent=\"body::after{content:\\\"\\\";display:block;position:relative;left:50%;transform:translateX(-50%);width:100vw;height:1px;background:#CAD5DF;margin:48px 0 8px 0;border:0;pointer-events:none;}\";document.head.appendChild(s);})()")
        }
        // aanel-divider-end

        try? await Task.sleep(seconds: 0.2)

        if isContinuousScrolling {
            await updateDocumentHeight()
            didCompleteGoTo()
            return
        }

        let location = pendingLocation
        await go(to: location.location, animated: location.animated)

        // aanel-settle-paginated: the first centre answer for this spread.
        // `notifyPagesDidChange` alone is not enough — it early-returns when
        // the progression range has not *changed*, which is exactly the case
        // for a spread that loads already showing page 1 (an opening, or a
        // mode-switch restore that lands at a resource start).
        aanelSchedulePageCentreEmit()

        // The rendering is sometimes very slow. So in case we don't show the first page of the resource, we add
        // a generous delay before showing the spread again.
        let delayed = !location.location.isStart
        try? await Task.sleep(seconds: delayed ? 0.3 : 0)
    }

    override func go(to direction: EPUBSpreadView.Direction, options: NavigatorGoOptions) async -> Bool {
        guard !viewModel.scroll, !isContinuousScrolling else {
            return await super.go(to: direction, options: options)
        }

        let factor: CGFloat = {
            switch direction {
            case .left:
                return -1
            case .right:
                return 1
            }
        }()

        guard scrollView.bounds.width > 0 else { return false }
        let offsetX = scrollView.bounds.width * factor
        let targetX = round((scrollView.contentOffset.x + offsetX) / offsetX) * offsetX
        guard 0 ..< scrollView.contentSize.width ~= targetX else {
            return false
        }

        // We use JavaScript instead of `UIScrollView.setContentOffset()` to
        // prevent glitches when turning pages without animation.
        // See https://github.com/readium/swift-toolkit/issues/737#issuecomment-4090386881
        //
        // `scrollBy` is used instead of `scrollTo` because RTL content uses
        // negative `window.scrollX` values in WKWebView, whereas UIKit's
        // `contentOffset.x` is always non-negative. A relative displacement
        // (`offsetX`) is coordinate-system agnostic and works for both LTR and
        // RTL.
        let behavior = options.animated ? "smooth" : "instant"
        await evaluateScript("window.scrollBy({ left: \(offsetX), behavior: '\(behavior)' });")

        if options.animated {
            // Waits for the scroll animation to finish.
            await withCheckedContinuation { continuation in
                let request = ScrollAnimationRequest(continuation)
                pendingScrollAnimation?.resume()
                pendingScrollAnimation = request

                // Safety net in case `scrollDidEnd` never fires. The identity
                // check on `request` ensures a stale timeout from a previous
                // request does not resume a newer one.
                Task { @MainActor in
                    try? await Task.sleep(seconds: 0.8)
                    scrollDidEnd(for: request)
                }
            }
        }

        return true
    }

    private struct PendingLocation {
        var location: PageLocation
        var animated: Bool
    }

    /// Location to scroll to in the resource once the page is loaded.
    private var pendingLocation: PendingLocation = .init(location: .start, animated: false)

    override func go(to location: PageLocation, animated: Bool) async {
        guard isSpreadLoaded else {
            // Delays moving to the location until the document is loaded.
            pendingLocation = PendingLocation(location: location, animated: animated)

            await waitGoToCompletion()
            return
        }

        if isContinuousScrolling {
            didCompleteGoTo()
            return
        }

        switch location {
        case let .locator(locator):
            await go(to: locator, animated: animated)
        case .start:
            await scroll(toProgression: 0, animated: animated)
        case .end:
            await scroll(toProgression: 1, animated: animated)
        }

        didCompleteGoTo()
    }

    private func waitGoToCompletion() async {
        await withCheckedContinuation { continuation in
            goToContinuations.append(continuation)
        }
    }

    private func didCompleteGoTo() {
        for cont in goToContinuations {
            cont.resume()
        }
        goToContinuations.removeAll()
    }

    private var estimatedDocumentHeight: CGFloat {
        max(bounds.height - contentInsets.top - contentInsets.bottom, 1)
    }

    override func preferredHeight(for width: CGFloat) -> CGFloat {
        guard isContinuousScrolling else {
            return super.preferredHeight(for: width)
        }
        let documentHeight = measuredDocumentHeight ?? estimatedDocumentHeight
        return max(aanelContinuousInsets.top + documentHeight + aanelContinuousInsets.bottom, 1)
    }

    override func targetYOffset(for location: PageLocation, viewportHeight: CGFloat, nearY: CGFloat?) async -> CGFloat? {
        guard isContinuousScrolling else {
            return await super.targetYOffset(for: location, viewportHeight: viewportHeight, nearY: nearY)
        }

        let pageHeight = preferredHeight(for: bounds.width)
        let maxOffset = max(pageHeight - viewportHeight, 0)

        // Exact by definition unless the locator branch falls back below.
        aanelLastTargetFromAnchor = true

        switch location {
        case .start:
            return 0
        case .end:
            return maxOffset
        case let .locator(locator):
            for attempt in 0 ..< 6 {
                if let rect = await locatorYOffset(for: locator, nearY: nearY.map { $0 - aanelContinuousInsets.top }) {
                    // aanel: centre the sentence's visible MASS at 50% of the
                    // viewport (top-at-45% left long sentences hanging mostly
                    // below centre — "tracking feels lazy/off-centre").
                    aanelLastTargetFromAnchor = true
                    let visibleMass = min(rect.height, viewportHeight * 0.5)
                    let centred = rect.top + visibleMass / 2 - viewportHeight * 0.5
                    return min(max(aanelContinuousInsets.top + centred, 0), maxOffset)
                }

                guard attempt < 5 else {
                    break
                }

                await updateDocumentHeight()
                try? await Task.sleep(seconds: 0.05)
            }

            // aanel: the progression fallback is a COARSE estimate (for
            // read-along locators it is the sidecar's chapter fraction, off
            // by 100-250pt) — mark it so goToIndex can land it provisionally
            // and report failure for text-anchored locators, letting the
            // caller's retry loop snap to the anchor-exact position once the
            // webview can resolve it (device trace 2026-08-07: mode-switch
            // recovery follows landed the fallback ~200pt low and reported
            // success — the exact landing then waited for the next sentence).
            aanelLastTargetFromAnchor = false

            if let progression = locator.locations.progression {
                let documentHeight = measuredDocumentHeight ?? estimatedDocumentHeight
                let centred = documentHeight * progression - viewportHeight * 0.5
                return min(max(aanelContinuousInsets.top + centred, 0), maxOffset)
            }

            return 0
        }
    }

    override func firstVisibleElementLocator(in visibleRect: CGRect) async -> Locator? {
        guard isContinuousScrolling else {
            return await super.firstVisibleElementLocator(in: visibleRect)
        }

        let webViewVisibleRect = convert(visibleRect, to: webView)
        guard let rectJSON = jsonString(for: webViewVisibleRect) else {
            return nil
        }

        let result = await evaluateScript("readiumContinuous.findFirstVisibleLocatorInRect(\(rectJSON));")
        do {
            let link = spread.first.link
            guard
                let json = try JSONValue(result.get()),
                let locator = try Locator(json: json)
            else {
                return nil
            }
            return locator.copy(href: link.url(), mediaType: link.mediaType ?? .xhtml)

        } catch {
            log(.error, error)
            return nil
        }
    }

    private func scheduleDocumentHeightUpdate(delay: TimeInterval = 0.05) {
        guard isContinuousScrolling else {
            return
        }

        documentHeightTask?.cancel()
        documentHeightTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            if delay > 0 {
                try? await Task.sleep(seconds: delay)
            }
            await self.updateDocumentHeight()
        }
    }

    private func updateDocumentHeight() async {
        guard isContinuousScrolling else {
            return
        }

        let result = await evaluateScript("readiumContinuous.contentHeight();")
        guard
            case let .success(value) = result,
            let number = value as? NSNumber
        else {
            return
        }

        let height = max(CGFloat(truncating: number), 1)
        guard abs((measuredDocumentHeight ?? 0) - height) > 0.5 else {
            return
        }

        measuredDocumentHeight = height
        webViewHeightConstraint.constant = height
        setNeedsLayout()
        onPreferredHeightChange?()
    }

    private func locatorYOffset(for locator: Locator, nearY: CGFloat?) async -> (top: CGFloat, height: CGFloat)? {
        guard let locatorJSON = try? locator.jsonString() else {
            return nil
        }

        let nearArg = nearY.map { String(format: "%.0f", $0) } ?? "null"
        let result = await evaluateScript("readiumContinuous.locatorYOffset(\(locatorJSON), \(nearArg));")
        guard
            case let .success(value) = result,
            let dict = value as? [String: Any],
            let top = (dict["top"] as? NSNumber).map({ CGFloat(truncating: $0) }),
            top.isFinite
        else {
            return nil
        }
        let height = (dict["height"] as? NSNumber).map { CGFloat(truncating: $0) } ?? 0
        return (top: top, height: height.isFinite ? max(0, height) : 0)
    }

    private func locatorRect(for locator: Locator) async -> CGRect? {
        guard let locatorJSON = try? locator.jsonString() else {
            return nil
        }

        let result = await evaluateScript("readiumContinuous.locatorRect(\(locatorJSON));")
        guard case let .success(value) = result else {
            return nil
        }

        return CGRect(json: value)
    }

    private func jsonString(for rect: CGRect) -> String? {
        let json: [String: CGFloat] = [
            "top": rect.minY,
            "left": rect.minX,
            "bottom": rect.maxY,
            "right": rect.maxX,
            "width": rect.width,
            "height": rect.height,
            "x": rect.minX,
            "y": rect.minY,
        ]

        guard
            let data = try? JSONSerialization.data(withJSONObject: json),
            let string = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return string
    }

    private var goToContinuations: [CheckedContinuation<Void, Never>] = []

    private var pendingScrollAnimation: ScrollAnimationRequest?

    /// Represents an in-flight animated page turn, waiting for the scroll
    /// animation to settle before completing.
    private class ScrollAnimationRequest {
        private var continuation: CheckedContinuation<Void, Never>?

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
        }

        /// Resumes the continuation. Safe to call multiple times; only the
        /// first call has any effect.
        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }

    private func scrollDidEnd(for request: ScrollAnimationRequest? = nil) {
        guard request == nil || pendingScrollAnimation === request else {
            return
        }
        pendingScrollAnimation?.resume()
        pendingScrollAnimation = nil
    }

    @discardableResult
    private func go(to locator: Locator, animated: Bool) async -> Bool {
        if !["", "#"].contains(locator.href.string) {
            guard
                let index = viewModel.readingOrder.firstIndexWithHREF(locator.href),
                spread.contains(index: index)
            else {
                log(.warning, "The locator's href is not in the spread")
                return false
            }
        }

        if locator.text.highlight != nil {
            return await scroll(toLocator: locator, animated: animated)
            // TODO: find the first fragment matching a tag ID (need a regex)
        } else if let id = locator.locations.fragments.first, !id.isEmpty {
            return await scroll(toTagID: id, animated: animated)
        } else {
            let progression = locator.locations.progression ?? 0
            return await scroll(toProgression: progression, animated: animated)
        }
    }

    /// Scrolls at given progression (from 0.0 to 1.0)
    @discardableResult
    private func scroll(toProgression progression: Double, animated: Bool) async -> Bool {
        guard progression >= 0, progression <= 1 else {
            log(.warning, "Scrolling to invalid progression \(progression)")
            return false
        }

        // Note: The JS layer does not take into account the scroll view's content inset. So it can't be used to reliably scroll to the top or the bottom of the page in scroll mode.
        if viewModel.scroll, !viewModel.verticalText, [0, 1].contains(progression) {
            var contentOffset = scrollView.contentOffset
            contentOffset.y = (progression == 0)
                ? -scrollView.contentInset.top
                : (scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom)
            scrollView.contentOffset = contentOffset
            return true
        } else {
            let dir = viewModel.readingProgression.rawValue
            await evaluateScript("readium.scrollToPosition(\'\(progression)\', \'\(dir)\', \(animated))")
            return true
        }
    }

    /// Scrolls at the tag with ID `tagID`.
    @discardableResult
    private func scroll(toTagID tagID: String, animated: Bool) async -> Bool {
        let result = await evaluateScript("readium.scrollToId(\'\(tagID)\', \(animated));")
        switch result {
        case let .success(value):
            return (value as? Bool) ?? false
        case let .failure(error):
            log(.error, error)
            return false
        }
    }

    /// Scrolls at the snippet matching the given text context.
    @discardableResult
    private func scroll(toLocator locator: Locator, animated: Bool) async -> Bool {
        guard let json = try? locator.jsonString() else {
            return false
        }
        let result = await evaluateScript("readium.scrollToLocator(\(json), \(animated));")
        switch result {
        case let .success(value):
            return (value as? Bool) ?? false
        case let .failure(error):
            log(.error, error)
            return false
        }
    }

    // MARK: - Progression

    /// Current progression range in the page.
    private var progression: ClosedRange<Double>?
    /// To check if a progression change was cancelled or not.
    private var previousProgression: ClosedRange<Double>?

    /// Called by the javascript code to notify that scrolling ended.
    private func progressionDidChange(_ body: Any) {
        guard
            isSpreadLoaded,
            let body = body as? [String: Any],
            var firstProgression = body["first"] as? Double,
            var lastProgression = body["last"] as? Double
        else {
            return
        }
        precondition(firstProgression <= lastProgression)
        firstProgression = min(max(firstProgression, 0.0), 1.0)
        lastProgression = min(max(lastProgression, 0.0), 1.0)

        if previousProgression == nil {
            previousProgression = progression
        }
        progression = firstProgression ... lastProgression

        setNeedsNotifyPagesDidChange()
    }

    private func setNeedsNotifyPagesDidChange() {
        // Makes sure we always receive the "ending scroll" event.
        // ie. https://stackoverflow.com/a/1857162/1474476
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(notifyPagesDidChange), object: nil)
        perform(#selector(notifyPagesDidChange), with: nil, afterDelay: 0.3)
    }

    @objc private func notifyPagesDidChange() {
        guard previousProgression != progression else {
            return
        }
        previousProgression = nil

        scrollDidEnd()
        delegate?.spreadViewPagesDidChange(self)
        // aanel-settle-paginated: the page under the reader changed and has
        // stopped moving — re-measure the centre. This is the paginated
        // analogue of the continuous surface's settle work item.
        aanelSchedulePageCentreEmit()
    }

    // MARK: - Scripts

    override func registerJSMessages() {
        super.registerJSMessages()
        registerJSMessage(named: "progressionChanged") { [weak self] in self?.progressionDidChange($0) }
        registerJSMessage(named: "continuousContentLayoutChanged") { [weak self] _ in
            self?.scheduleDocumentHeightUpdate(delay: 0)
        }
    }

    // MARK: - WKNavigationDelegate

    override func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        super.webView(webView, didFinish: navigation)

        // Fixes https://github.com/readium/r2-navigator-swift/issues/141 by disabling the native
        // double-tap gesture.
        // It's an acceptable fix because reflowable resources are not supposed to handle double-tap
        // since there's no zooming capabilities. This doesn't prevent JavaScript to handle
        // double-tap manually.
        webView.removeDoubleTapGestureRecognizer()
    }

    // MARK: - UIScrollViewDelegate

    override func scrollViewDidScroll(_ scrollView: UIScrollView) {
        super.scrollViewDidScroll(scrollView)
        setNeedsNotifyPagesDidChange()
    }
}
