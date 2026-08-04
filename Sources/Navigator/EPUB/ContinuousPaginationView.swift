//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import ReadiumShared
import UIKit

/// A vertical pagination container used in continuous scroll mode.
final class ContinuousPaginationView: UIView, Loggable, PaginationContainerView {
    weak var delegate: PaginationViewDelegate?

    private(set) var pageCount: Int = 0
    private(set) var currentIndex: Int = 0
    private(set) var loadedViews: [Int: UIView & PageView] = [:]

    var currentView: (UIView & PageView)? {
        loadedViews[currentIndex]
    }

    var viewportRect: CGRect {
        CGRect(origin: scrollView.contentOffset, size: scrollView.bounds.size)
    }

    private let preloadPreviousPositionCount: Int
    private let preloadNextPositionCount: Int
    private let scrollView = UIScrollView()

    private var estimatedPageHeight: CGFloat {
        max(scrollView.bounds.height, bounds.height, 1)
    }

    private var pageHeights: [CGFloat] = []
    private var loadingIndexQueue: [Int] = []
    private var onViewLoadedCallbacks: [Int: CompletionList] = [:]
    private var readyViewIndices: Set<Int> = []
    private var loadPagesTask: Task<Void, Never>?
    private var pendingReloadNavigationTask: Task<Void, Never>?

    private var scrollAnimationContinuation: CheckedContinuation<Void, Never>?
    private var isAdjustingContentOffset = false

    // aanel-settle-continuous-begin: state for the gesture-gated centre
    // tracking (resume-preview marker + scroll-detach events). Mirrors the
    // per-spread emitter that non-continuous scroll mode uses.
    private var aanelSettleWorkItem: DispatchWorkItem?
    private var aanelLastMoveEmitAt: TimeInterval = 0
    // aanel-settle-continuous-end

    // aanel: set when a user touch interrupts an in-flight programmatic
    // scroll animation — goToIndex's convergence loop checks it to stop
    // fighting the user.
    private var aanelUserInterrupted = false

    var isScrollEnabled: Bool {
        didSet { scrollView.isScrollEnabled = isScrollEnabled }
    }

    init(
        frame: CGRect,
        preloadPreviousPositionCount: Int,
        preloadNextPositionCount: Int,
        isScrollEnabled: Bool
    ) {
        self.preloadPreviousPositionCount = preloadPreviousPositionCount
        self.preloadNextPositionCount = preloadNextPositionCount
        self.isScrollEnabled = isScrollEnabled

        super.init(frame: frame)

        scrollView.delegate = self
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.flexibleHeight, .flexibleWidth]
        scrollView.alwaysBounceHorizontal = false
        scrollView.alwaysBounceVertical = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.isScrollEnabled = isScrollEnabled
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        addSubview(scrollView)

        // Keep the same content-inset behavior as PaginationView across iOS versions.
        insertSubview(UIView(frame: .zero), at: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        guard pageCount > 0 else {
            scrollView.contentSize = bounds.size
            return
        }

        let width = scrollView.bounds.width
        var y: CGFloat = 0

        for index in 0 ..< pageCount {
            let height = pageHeights.getOrNil(index) ?? estimatedPageHeight
            if let view = loadedViews[index] {
                view.frame = CGRect(x: 0, y: y, width: width, height: height)
            }
            y += height
        }

        scrollView.contentSize = CGSize(width: width, height: max(y, scrollView.bounds.height))
        clampContentOffsetIfNeeded()
    }

    override func willMove(toSuperview newSuperview: UIView?) {
        super.willMove(toSuperview: newSuperview)

        guard newSuperview == nil else {
            return
        }

        loadPagesTask?.cancel()
        pendingReloadNavigationTask?.cancel()
        for (_, view) in loadedViews {
            (view as? ContinuousPageView)?.onPreferredHeightChange = nil
            view.removeFromSuperview()
        }
        loadedViews.removeAll()
        onViewLoadedCallbacks.removeAll()
        readyViewIndices.removeAll()
    }

    func reloadAtIndex(
        _ index: Int,
        location: PageLocation,
        pageCount: Int,
        readingProgression: ReadingProgression,
        navigateToLocationAfterReload: Bool
    ) {
        precondition(pageCount >= 1)
        precondition(0 ..< pageCount ~= index)
        NSLog("[AanelNav] reloadAtIndex %d navAfter=%d", index, navigateToLocationAfterReload ? 1 : 0)

        self.pageCount = pageCount
        pageHeights = Array(repeating: estimatedPageHeight, count: pageCount)

        loadPagesTask?.cancel()
        pendingReloadNavigationTask?.cancel()
        loadingIndexQueue.removeAll()
        onViewLoadedCallbacks.removeAll()
        readyViewIndices.removeAll()

        for (_, view) in loadedViews {
            (view as? ContinuousPageView)?.onPreferredHeightChange = nil
            view.removeFromSuperview()
        }
        loadedViews.removeAll()

        synchronizeLayout()

        currentIndex = index
        scrollView.contentOffset = CGPoint(x: 0, y: yOffset(before: index))

        setCurrentIndex(index)

        guard navigateToLocationAfterReload else {
            return
        }

        pendingReloadNavigationTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            defer {
                self.pendingReloadNavigationTask = nil
            }

            _ = await self.goToIndex(
                index,
                location: location,
                options: NavigatorGoOptions(animated: false),
                cancelPendingReloadNavigation: false
            )
        }
    }

    func goToIndex(_ index: Int, location: PageLocation, options: NavigatorGoOptions) async -> Bool {
        await goToIndex(index, location: location, options: options, cancelPendingReloadNavigation: true)
    }

    private func goToIndex(
        _ index: Int,
        location: PageLocation,
        options: NavigatorGoOptions,
        cancelPendingReloadNavigation: Bool
    ) async -> Bool {
        guard 0 ..< pageCount ~= index else {
            return false
        }

        if cancelPendingReloadNavigation {
            pendingReloadNavigationTask?.cancel()
            pendingReloadNavigationTask = nil
        }

        setCurrentIndex(index)
        // aanel: 2s was not enough on device — LCP decryption + a heavy
        // chapter can exceed it, and the old hard-fail made the jump a silent
        // no-op ("unreliable jump controls"). Wait longer, and on timeout fall
        // through to the estimated offset below instead of failing outright: a
        // slightly-off landing beats a dead control.
        let isReady = await waitUntilViewIsLoaded(at: index, timeout: 8.0)
        synchronizeLayout()
        NSLog("[AanelNav] goToIndex %d ready=%d loc=%@", index, isReady ? 1 : 0, String(describing: location))

        if !isReady {
            log(.warning, "Timed out waiting for continuous page \(index); landing on estimated offset for \(location)")
        }

        // aanel-converge: freshly loaded neighbours can re-measure DURING the
        // animated scroll; the compensation in updatePageHeight interrupts the
        // animation (resuming the waiter), which would otherwise land us on a
        // stale target. Re-resolve and re-animate until the landing is stable
        // (heights settle after one or two passes), unless the user grabbed
        // the surface mid-flight — never fight the user.
        let animated = options.animated && !UIAccessibility.isReduceMotionEnabled
        aanelUserInterrupted = false
        for pass in 0 ..< 3 {
            let baseOffset = yOffset(before: index)
            let pageHeight = pageHeights.getOrNil(index) ?? estimatedPageHeight
            let localOffset = (
                isReady
                    ? await resolvedTargetYOffset(at: index, location: location, viewportHeight: scrollView.bounds.height)
                    : nil
            ) ?? defaultTargetYOffset(for: location, pageHeight: pageHeight, viewportHeight: scrollView.bounds.height)
            guard localOffset.isFinite else {
                return pass > 0
            }
            // aanel-centre: land locator targets ~45% down the viewport
            // (parity with the pre-continuous Rulla smooth-scroll centring)
            // instead of at the viewport top edge under the chrome.
            // .start/.end keep upstream semantics.
            var adjustedLocalOffset = localOffset
            if case .locator = location {
                adjustedLocalOffset = max(0, localOffset - scrollView.bounds.height * 0.45)
            }
            let targetY = clampYOffset(baseOffset + adjustedLocalOffset)

            if abs(scrollView.contentOffset.y - targetY) <= 2 {
                NSLog("[AanelNav] converge pass=%d stable y=%.0f (base=%.0f local=%.0f adj=%.0f)", pass, targetY, baseOffset, localOffset, adjustedLocalOffset)
                break
            }

            NSLog("[AanelNav] converge pass=%d cur=%.0f -> target=%.0f (base=%.0f local=%.0f adj=%.0f)", pass, scrollView.contentOffset.y, targetY, baseOffset, localOffset, adjustedLocalOffset)
            await setContentOffset(CGPoint(x: 0, y: targetY), animated: animated)

            if aanelUserInterrupted {
                break
            }
        }
        updateCurrentIndexFromViewport()
        delegate?.paginationViewDidUpdateViews(self)
        return true
    }

    func go(to direction: EPUBSpreadView.Direction, options: NavigatorGoOptions, readingProgression: ReadingProgression) async -> Bool {
        let isForward = switch readingProgression {
        case .ltr:
            direction == .right
        case .rtl:
            direction == .left
        }
        let delta = scrollView.bounds.height * (isForward ? 1 : -1)
        let targetY = clampYOffset(scrollView.contentOffset.y + delta)

        guard abs(scrollView.contentOffset.y - targetY) > 0.5 else {
            return false
        }

        await setContentOffset(CGPoint(x: 0, y: targetY), animated: options.animated && !UIAccessibility.isReduceMotionEnabled)
        updateCurrentIndexFromViewport()
        delegate?.paginationViewDidUpdateViews(self)
        return true
    }

    private func setCurrentIndex(_ index: Int) {
        currentIndex = index

        scheduleLoadPage(at: index)
        let lastIndex = scheduleLoadPages(from: index, upToPositionCount: preloadNextPositionCount, direction: .forward)
        let firstIndex = scheduleLoadPages(from: index, upToPositionCount: preloadPreviousPositionCount, direction: .backward)

        for (loadedIndex, view) in loadedViews {
            guard firstIndex ... lastIndex ~= loadedIndex else {
                (view as? ContinuousPageView)?.onPreferredHeightChange = nil
                view.removeFromSuperview()
                loadedViews.removeValue(forKey: loadedIndex)
                readyViewIndices.remove(loadedIndex)
                continue
            }
        }

        loadPages()
    }

    private func loadPages() {
        loadPagesTask?.cancel()
        loadPagesTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await self.loadNextPage()
            self.delegate?.paginationViewDidUpdateViews(self)
        }
    }

    private func loadNextPage() async {
        guard let index = loadingIndexQueue.popFirst() else {
            return
        }

        if loadedViews[index] == nil, let view = delegate?.paginationView(self, pageViewAtIndex: index) {
            loadedViews[index] = view
            scrollView.addSubview(view)
            bindContinuousPageViewCallbacks(view, index: index)
            synchronizeLayout()
        }

        guard let view = loadedViews[index] else {
            return
        }

        await view.go(to: .start, animated: false)
        updatePageHeight(at: index)
        synchronizeLayout()
        readyViewIndices.insert(index)
        onViewLoadedCallbacks[index]?.complete()
        onViewLoadedCallbacks[index] = nil

        await loadNextPage()
    }

    private func bindContinuousPageViewCallbacks(_ view: UIView & PageView, index: Int) {
        guard let view = view as? (UIView & ContinuousPageView) else {
            return
        }

        view.onPreferredHeightChange = { [weak self] in
            DispatchQueue.main.async {
                self?.updatePageHeight(at: index)
            }
        }
    }

    private func updatePageHeight(at index: Int) {
        guard let view = loadedViews[index] else {
            return
        }

        let oldHeight = pageHeights.getOrNil(index) ?? estimatedPageHeight
        let newHeight: CGFloat = {
            guard let view = view as? (UIView & ContinuousPageView) else {
                return oldHeight
            }
            return max(view.preferredHeight(for: scrollView.bounds.width), 1)
        }()

        guard abs(newHeight - oldHeight) > 0.5 else {
            return
        }

        let pageMinY = yOffset(before: index)
        let viewportMinY = viewportRect.minY
        pageHeights[index] = newHeight

        if pageMinY < viewportMinY {
            isAdjustingContentOffset = true
            // aanel: a direct contentOffset write CANCELS an in-flight
            // animated setContentOffset without ever firing
            // scrollViewDidEndScrollingAnimation — resume the waiter first, or
            // goToIndex hangs on its continuation and the navigator is stuck
            // in .jumping, silently rejecting every later navigation. The
            // convergence loop in goToIndex re-targets after the interrupt.
            scrollAnimationContinuation?.resume()
            scrollAnimationContinuation = nil
            scrollView.contentOffset.y += newHeight - oldHeight
            isAdjustingContentOffset = false
        }

        setNeedsLayout()
        layoutIfNeeded()
        delegate?.paginationViewDidUpdateViews(self)
    }

    // aanel: lets the navigator skip the pre-jump window rebuild when the
    // target spread's view is already built (see the go(to:) anchored-jump
    // path — rebuilding on every sentence follow caused visible churn).
    func isViewReady(at index: Int) -> Bool {
        readyViewIndices.contains(index)
    }

    private func waitUntilViewIsLoaded(at index: Int, timeout: TimeInterval = 2.0) async -> Bool {
        guard !readyViewIndices.contains(index) else {
            return true
        }

        let sleepNanoseconds: UInt64 = 50_000_000
        let timeoutNanoseconds = UInt64(max(timeout, 0) * 1_000_000_000)
        let maxAttempts = max(Int(timeoutNanoseconds / sleepNanoseconds), 1)

        for _ in 0 ..< maxAttempts {
            if readyViewIndices.contains(index) {
                return true
            }
            try? await Task.sleep(nanoseconds: sleepNanoseconds)
        }

        let isReady = readyViewIndices.contains(index)
        if !isReady {
            log(.warning, "Continuous page \(index) did not finish loading within \(timeout)s")
        }
        return isReady
    }

    private func synchronizeLayout() {
        setNeedsLayout()
        layoutIfNeeded()
    }

    private func targetYOffset(at index: Int, location: PageLocation, viewportHeight: CGFloat) async -> CGFloat? {
        guard let view = loadedViews[index] as? (UIView & ContinuousPageView) else {
            return nil
        }
        return await view.targetYOffset(for: location, viewportHeight: viewportHeight)
    }

    private func resolvedTargetYOffset(at index: Int, location: PageLocation, viewportHeight: CGFloat) async -> CGFloat? {
        let attemptCount: Int = {
            guard case let .locator(locator) = location else {
                return 1
            }
            return (locator.locations.progression == nil) ? 6 : 1
        }()

        for attempt in 0 ..< attemptCount {
            if let offset = await targetYOffset(at: index, location: location, viewportHeight: viewportHeight), offset.isFinite {
                return offset
            }

            guard attempt < attemptCount - 1 else {
                break
            }

            synchronizeLayout()
            try? await Task.sleep(seconds: 0.05)
        }

        return nil
    }

    private func defaultTargetYOffset(for location: PageLocation, pageHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        switch location {
        case .start:
            return 0
        case .end:
            return max(pageHeight - viewportHeight, 0)
        case let .locator(locator):
            // aanel: last-resort estimate — a text-anchored locator without
            // progression lands at the chapter start rather than killing the
            // navigation (paired with the goToIndex timeout fallback).
            return max(0, pageHeight * (locator.locations.progression ?? 0))
        }
    }

    private func setContentOffset(_ contentOffset: CGPoint, animated: Bool) async {
        if animated {
            await withCheckedContinuation { continuation in
                scrollAnimationContinuation?.resume()
                scrollAnimationContinuation = continuation
                scrollView.setContentOffset(contentOffset, animated: true)
            }
        } else {
            scrollView.contentOffset = contentOffset
        }
    }

    private func clampContentOffsetIfNeeded() {
        let clamped = clampYOffset(scrollView.contentOffset.y)
        guard abs(clamped - scrollView.contentOffset.y) > 0.5 else {
            return
        }

        isAdjustingContentOffset = true
        scrollView.contentOffset.y = clamped
        isAdjustingContentOffset = false
    }

    private func clampYOffset(_ y: CGFloat) -> CGFloat {
        let maxOffset = max(scrollView.contentSize.height - scrollView.bounds.height, 0)
        return min(max(y, 0), maxOffset)
    }

    private func yOffset(before index: Int) -> CGFloat {
        pageHeights.prefix(index).reduce(0, +)
    }

    private func updateCurrentIndexFromViewport() {
        guard pageCount > 0 else {
            return
        }

        let offset = clampYOffset(scrollView.contentOffset.y + 1)
        var accumulatedHeight: CGFloat = 0

        for index in 0 ..< pageCount {
            accumulatedHeight += pageHeights.getOrNil(index) ?? estimatedPageHeight
            if offset < accumulatedHeight || index == pageCount - 1 {
                guard currentIndex != index else {
                    return
                }
                setCurrentIndex(index)
                return
            }
        }
    }

    @discardableResult
    private func scheduleLoadPage(at index: Int) -> Bool {
        guard 0 ..< pageCount ~= index else {
            return false
        }

        loadingIndexQueue.removeAll { $0 == index }
        loadingIndexQueue.append(index)
        return true
    }

    private func scheduleLoadPages(from sourceIndex: Int, upToPositionCount positionCount: Int, direction: PageIndexDirection) -> Int {
        let index = sourceIndex + direction.rawValue
        guard
            positionCount > 0,
            scheduleLoadPage(at: index),
            let indexPositionCount = delegate?.paginationView(self, positionCountAtIndex: index)
        else {
            return sourceIndex
        }

        return scheduleLoadPages(
            from: index,
            upToPositionCount: positionCount - indexPositionCount,
            direction: direction
        )
    }

    private enum PageIndexDirection: Int {
        case forward = 1
        case backward = -1
    }
}

extension ContinuousPaginationView: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isAdjustingContentOffset else {
            return
        }

        updateCurrentIndexFromViewport()
        delegate?.paginationViewDidUpdateViews(self)

        // aanel-settle-continuous: gesture-gated centre tracking. While a USER
        // gesture is in flight: every 0.12s emit the centre locator on
        // AanelRulla.scrollMove (live resume-preview marker + scroll detach);
        // 0.1s after the last frame, re-confirmed stopped, emit the
        // authoritative AanelRulla.scrollSettle. Programmatic navigation
        // animates via setContentOffset, which never sets isDragging/
        // isDecelerating, so it stays silent by construction.
        if scrollView.isDragging || scrollView.isDecelerating {
            let now = Date().timeIntervalSinceReferenceDate
            if now - aanelLastMoveEmitAt >= 0.12 {
                aanelLastMoveEmitAt = now
                aanelEmitCentreLocator(noteName: "AanelRulla.scrollMove")
            }
            aanelSettleWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self = self,
                      !self.scrollView.isDragging,
                      !self.scrollView.isDecelerating else { return }
                self.aanelEmitCentreLocator(noteName: "AanelRulla.scrollSettle")
            }
            aanelSettleWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
        }
    }

    // aanel-settle-continuous: probe fan-out. The viewport centre can sit in
    // the inter-chapter gap (trailing/leading padding, divider, heading
    // margins) where a hit-test finds no text — so for the authoritative
    // SETTLE, probe the centre first and fan outward (±8/16/24/32% of the
    // viewport), accepting the first strict text hit; probes map to whichever
    // spread lies under them, so the fan crosses chapter boundaries naturally.
    // The last probe (centre again) is forced so a settle is never silently
    // dropped. Throttled MOVE events keep the cheap single forced probe — the
    // live marker is approximate by design.
    private func aanelEmitCentreLocator(noteName: String) {
        let isSettle = noteName.hasSuffix("scrollSettle")
        let fractions: [CGFloat] = isSettle
            ? [0, -0.08, 0.08, -0.16, 0.16, -0.24, 0.24, -0.32, 0.32]
            : [0]
        aanelProbe(noteName: noteName, fractions: fractions, index: 0)
    }

    private func aanelProbe(noteName: String, fractions: [CGFloat], index: Int) {
        let viewportHeight = scrollView.bounds.height
        let centreY = scrollView.contentOffset.y + viewportHeight / 2
        let isLast = index >= fractions.count
        let y = isLast ? centreY : centreY + fractions[index] * viewportHeight
        let point = CGPoint(x: scrollView.bounds.width / 2, y: y)

        guard let view = loadedViews.values.first(where: {
            $0.frame.minY <= point.y && point.y < $0.frame.maxY
        }), let spreadView = view as? EPUBReflowableSpreadView else {
            if isLast { return }
            aanelProbe(noteName: noteName, fractions: fractions, index: index + 1)
            return
        }

        spreadView.aanelEmitCentreLocator(
            atLocalPoint: CGPoint(x: point.x, y: point.y - view.frame.minY),
            noteName: noteName,
            force: isLast
        ) { [weak self] emitted in
            guard !emitted, !isLast else { return }
            self?.aanelProbe(noteName: noteName, fractions: fractions, index: index + 1)
        }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        scrollAnimationContinuation?.resume()
        scrollAnimationContinuation = nil
    }

    // aanel: a user touch also cancels an in-flight animated setContentOffset
    // without firing didEndScrollingAnimation — resume the waiter (so the
    // pending goTo completes instead of leaking its continuation and jamming
    // the navigator state machine) and flag the interruption so the
    // convergence loop yields to the user.
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        if scrollAnimationContinuation != nil {
            aanelUserInterrupted = true
            scrollAnimationContinuation?.resume()
            scrollAnimationContinuation = nil
        }
    }
}
