import XCTest
import SwiftUI
import UIKit
@testable import OpenNotes

@MainActor
final class PaginationTests: XCTestCase {
    func testRetiringHostDoesNotChangeZoomGesturesOfReplacementHost() {
        let canvas = InkCanvasView()
        let previous = PageScrollView(canvas: canvas)
        let replacement = PageScrollView(canvas: canvas)
        previous.detachInteractions()
        XCTAssertFalse(canvas.pinchGestureRecognizer?.isEnabled ?? true)
        XCTAssertTrue(replacement.zoomGesture.view === replacement)
        replacement.detachInteractions()
        XCTAssertTrue(canvas.pinchGestureRecognizer?.isEnabled ?? false)
        XCTAssertNil(replacement.zoomGesture.view)
    }
    func testZoomOutBoundsTheAnchorOffsetAndCentersFittedPage() {
        let view = PageScrollView(canvas: InkCanvasView())
        view.frame = CGRect(x: 0, y: 0, width: 744, height: 893)
        view.pageSize = CGSize(width: 794, height: 1123); view.layoutIfNeeded()
        let offset = view.boundedOffset(CGPoint(x: -63.313, y: 66.696))
        XCTAssertEqual(offset.x, -view.canvas.contentInset.left, accuracy: 0.01)
        XCTAssertEqual(offset.y, -view.canvas.contentInset.top, accuracy: 0.01)
        view.canvas.setZoomScale(2, animated: false); view.alignBackground()
        XCTAssertEqual(view.boundedOffset(CGPoint(x: 9000, y: -9000)), CGPoint(x: 844, y: 0))
    }
    func testFittedPageTracksViewportResizeAndPreservesIntentionalZoom() {
        let view = PageScrollView(canvas: InkCanvasView())
        view.frame = CGRect(x: 0, y: 0, width: 744, height: 945)
        view.pageSize = CGSize(width: 794, height: 1123)
        view.layoutIfNeeded()
        let originalFit = view.canvas.minimumZoomScale
        XCTAssertTrue(view.pageTurn.shouldBegin(velocity: CGPoint(x: -250, y: 0)))
        view.frame.size.height -= 52
        view.layoutIfNeeded()
        XCTAssertLessThan(view.canvas.minimumZoomScale, originalFit)
        XCTAssertEqual(view.canvas.zoomScale, view.canvas.minimumZoomScale, accuracy: 0.001,
                       "Settling editor bars must keep a fitted page fitted, so the next swipe still navigates")
        XCTAssertTrue(view.pageTurn.shouldBegin(velocity: CGPoint(x: -250, y: 0)))
        view.canvas.setZoomScale(1.4, animated: false)
        view.frame.size.height -= 52
        view.layoutIfNeeded()
        XCTAssertEqual(view.canvas.zoomScale, 1.4, accuracy: 0.001)
        XCTAssertFalse(view.pageTurn.shouldBegin(velocity: CGPoint(x: -250, y: 0)))
    }

    func testZoomedPageTurnsOnlyAtHorizontalEdge() {
        let view = PageScrollView(canvas: InkCanvasView())
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 600)
        view.pageSize = CGSize(width: 794, height: 1123); view.layoutIfNeeded()
        view.canvas.setZoomScale(2, animated: false); view.alignBackground()
        let left = -view.canvas.adjustedContentInset.left
        let right = view.canvas.contentSize.width - view.canvas.bounds.width + view.canvas.adjustedContentInset.right
        view.canvas.contentOffset.x = (left + right) / 2
        XCTAssertFalse(view.pageTurn.shouldBegin(velocity: CGPoint(x: -300, y: 0)))
        XCTAssertFalse(view.pageTurn.shouldBegin(velocity: CGPoint(x: 300, y: 0)))
        view.canvas.contentOffset.x = right
        XCTAssertTrue(view.pageTurn.shouldBegin(velocity: CGPoint(x: -300, y: 0)))
        XCTAssertFalse(view.pageTurn.shouldBegin(velocity: CGPoint(x: 300, y: 0)))
        view.canvas.contentOffset.x = left
        XCTAssertTrue(view.pageTurn.shouldBegin(velocity: CGPoint(x: 300, y: 0)))
        XCTAssertFalse(view.pageTurn.shouldBegin(velocity: CGPoint(x: -300, y: 0)))
    }

    func testViewportReopenRestoresFitAcrossSizesAndPreservesLegacyZoom() throws {
        let noteID = UUID(), pageID = UUID()
        let key = "viewport-\(noteID)-\(pageID)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        func makeView(height: CGFloat) -> PageScrollView {
            let view = PageScrollView(canvas: InkCanvasView())
            view.frame = CGRect(x: 0, y: 0, width: 744, height: height)
            view.pageSize = CGSize(width: 794, height: 1123)
            view.restorePosition(pageID, noteID: noteID)
            view.layoutIfNeeded()
            return view
        }
        let first = makeView(height: 945)
        first.savePosition()
        XCTAssertEqual(try XCTUnwrap(UserDefaults.standard.array(forKey: key)).count, 4)
        let reopened = makeView(height: 893)
        XCTAssertEqual(reopened.canvas.zoomScale, reopened.canvas.minimumZoomScale, accuracy: 0.001)
        XCTAssertTrue(reopened.pageTurn.shouldBegin(velocity: CGPoint(x: -250, y: 0)))
        UserDefaults.standard.set([1.25, 397.0, 561.5], forKey: key)
        let legacy = makeView(height: 893)
        XCTAssertEqual(legacy.canvas.zoomScale, 1.25, accuracy: 0.001, "Existing three-value viewports retain the user's zoom")
        XCTAssertFalse(legacy.pageTurn.shouldBegin(velocity: CGPoint(x: -250, y: 0)))
        XCTAssertEqual(PageScrollView.restoredZoom([1.4, 397, 561.5, 0.813], fit: 0.767), 1.4)
        XCTAssertNil(PageScrollView.restoredZoom([.nan, 397, 561.5], fit: 0.767))
        XCTAssertNil(PageScrollView.restoredZoom([0, 397, 561.5], fit: 0.767))
        XCTAssertNil(PageScrollView.restoredZoom([1, 397], fit: 0.767))
    }

    func testReleaseReversalAndNotebookBoundaries() {
        XCTAssertTrue(InteractivePageTurn.shouldCommit(progress: 0.5, speed: 0, hasPage: true, canCreate: false))
        XCTAssertTrue(InteractivePageTurn.shouldCommit(progress: 0.08, speed: 900, hasPage: true, canCreate: false))
        XCTAssertFalse(InteractivePageTurn.shouldCommit(progress: 0.5, speed: -900, hasPage: true, canCreate: false), "Reversing the drag cancels the turn")
        XCTAssertFalse(InteractivePageTurn.shouldCommit(progress: 0.64, speed: 900, hasPage: false, canCreate: true))
        XCTAssertTrue(InteractivePageTurn.shouldCommit(progress: 0.7, speed: 0, hasPage: false, canCreate: true))
        XCTAssertFalse(InteractivePageTurn.shouldCommit(progress: 0.8, speed: 0, hasPage: false, canCreate: false))
    }

    func testDismantlingRemovesPagingGestureFromPersistentCanvas() async throws {
        let store = LibraryStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        await store.load()
        let created = await store.create()
        let session = EditorSession(store: store, noteID: try XCTUnwrap(created))
        let coordinator = WritingCanvas.Coordinator(session: session, zoomWindow: false)
        for _ in 0..<20 {
            let view = PageScrollView(canvas: session.canvas)
            coordinator.container = view
            let gesture = view.pageTurn.gesture
            XCTAssertEqual(gesture.maximumNumberOfTouches, 1, "A pinch must not start a one-finger page turn")
            WritingCanvas.dismantleUIView(view, coordinator: coordinator)
            XCTAssertFalse(session.canvas.gestureRecognizers?.contains(where: { $0 === gesture }) == true,
                           "Reopening the same notebook must not accumulate paging recognizers")
        }
    }

    func testZeroTranslationUsesVelocityAndCancelledTurnDoesNotNavigate() async throws {
        let view = PageScrollView(canvas: InkCanvasView())
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 600)
        view.pageSize = CGSize(width: 794, height: 1123)
        view.layoutIfNeeded()
        let baseViews = view.subviews
        view.pageTurn.canNext = true
        var directions: [Int] = []
        view.pageTurn.prepare = { if $0 != 0 { directions.append($0) } }
        var navigations = 0
        view.onNavigate = { _ in navigations += 1; return true }
        let pan = PaginationPan()
        pan.phase = .began; pan.speed = CGPoint(x: -300, y: 0)
        view.pageTurn.drag(pan)
        XCTAssertEqual(directions, [1], "UIKit can report zero translation at the beginning")
        pan.phase = .cancelled; pan.offset = CGPoint(x: -300, y: 0)
        view.pageTurn.drag(pan)
        try await waitUntil { !view.pageTurn.committing && view.subviews.elementsEqual(baseViews, by: { $0 === $1 }) }
        XCTAssertEqual(navigations, 0)
        XCTAssertTrue(view.pageTurn.shouldBegin(velocity: CGPoint(x: -300, y: 0)))
    }

    func testInterruptedNavigationIgnoresLateCompletion() async throws {
        let view = PageScrollView(canvas: InkCanvasView())
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 600)
        view.pageSize = CGSize(width: 794, height: 1123); view.layoutIfNeeded()
        let turn = view.pageTurn
        turn.canNext = true; turn.pageInstalled(UUID())
        var completions: [CheckedContinuation<Bool, Never>] = []
        view.onNavigate = { _ in await withCheckedContinuation { completions.append($0) } }
        func begin() {
            let pan = PaginationPan()
            pan.phase = .began; pan.offset.x = -10; turn.drag(pan)
            pan.phase = .ended; pan.offset.x = -240; turn.drag(pan)
        }
        begin()
        try await waitUntil { completions.count == 1 }
        turn.clear()
        begin()
        try await waitUntil { completions.count == 2 }
        completions[0].resume(returning: true)
        await Task.yield()
        XCTAssertTrue(turn.committing, "An obsolete completion must not remove the new transition")
        turn.pageInstalled(UUID()); completions[1].resume(returning: true)
        try await waitUntil { !turn.committing }
        XCTAssertTrue(turn.shouldBegin(velocity: CGPoint(x: -300, y: 0)))
    }

    func testHostedTwentyRoundTripsMultiplePagesZoomAndReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LibraryStore(root: root)
        await store.load()
        let created = await store.create()
        let id = try XCTUnwrap(created)
        let first = try XCTUnwrap(store.library.firstPage(in: id)).id
        let secondResult = await store.addPage(noteID: id, after: first)
        let second = try XCTUnwrap(secondResult)
        let thirdResult = await store.addPage(noteID: id, after: second)
        let third = try XCTUnwrap(thirdResult)
        if var smallPage = store.library.page(id: third) { smallPage.width = 400; smallPage.height = 600; store.updatePage(smallPage) }
        let preferenceName = "PaginationTests-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: preferenceName))
        defer { preferences.removePersistentDomain(forName: preferenceName) }
        let session = EditorSession(store: store, noteID: id, preferences: preferences)
        await session.open(first)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = UIScreen.main.bounds
        defer { window.endEditing(true); window.isHidden = true; window.rootViewController = nil }
        var host: UIHostingController<EditorScreen>? = UIHostingController(rootView: EditorScreen(store: store, noteID: id, session: session))
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await waitUntil { !session.busy && ((session.canvas.superview as? PageScrollView)?.bounds.width ?? 0) > 100 }
        let view = try XCTUnwrap(session.canvas.superview as? PageScrollView)
        var completed = 0
        func turn(_ direction: Int, to target: UUID, canPageAgain: Bool = true) async throws {
            let pan = PaginationPan()
            pan.offset = CGPoint(x: -CGFloat(direction) * 12, y: 0); pan.phase = .began
            view.pageTurn.drag(pan)
            let preview = try XCTUnwrap(view.subviews.last?.subviews.compactMap { $0 as? UIImageView }.first)
            let incomingFrame = preview.frame
            pan.offset.x = -CGFloat(direction) * view.bounds.width * 0.55; pan.phase = .ended
            view.pageTurn.drag(pan)
            try await waitUntil { session.page?.id == target && !session.busy && !view.pageTurn.committing }
            XCTAssertEqual((session.canvas.delegate as? WritingCanvas.Coordinator)?.pageID, target)
            if canPageAgain { XCTAssertTrue(view.pageTurn.shouldBegin(velocity: CGPoint(x: 300, y: 0))) }
            else if view.canvas.contentOffset.x > -view.canvas.adjustedContentInset.left + 1 {
                XCTAssertFalse(view.pageTurn.shouldBegin(velocity: CGPoint(x: 300, y: 0)))
            }
            let geometry = "Turn \(completed), target size \(view.pageSize), zoom \(view.canvas.zoomScale), offset \(view.canvas.contentOffset), insets \(view.canvas.contentInset)"
            XCTAssertEqual(incomingFrame.minX, view.paper.frame.minX, accuracy: 1, geometry)
            XCTAssertEqual(incomingFrame.minY, view.paper.frame.minY, accuracy: 1, geometry)
            XCTAssertEqual(incomingFrame.width, view.paper.frame.width, accuracy: 1)
            XCTAssertEqual(incomingFrame.height, view.paper.frame.height, accuracy: 1)
            completed += 1
        }
        for cycle in 0..<20 {
            try await turn(1, to: second)
            if cycle.isMultiple(of: 5) { try await turn(1, to: third); try await turn(-1, to: second) }
            try await turn(-1, to: first)
        }
        XCTAssertEqual(completed, 48)
        XCTAssertEqual(store.library.pages(in: id).count, 3)
        let evidence = XCTAttachment(string: "48 hosted turns: 20 next/previous round trips, 4 visits to page 3; every turn waited for target canvas installation and interaction release. OS: \(UIDevice.current.systemVersion)")
        evidence.name = "Pagination repetition"; evidence.lifetime = .keepAlways; add(evidence)
        UserDefaults.standard.set([1.2, 397.0, 561.5], forKey: "viewport-\(id)-\(second)")
        try await turn(1, to: second, canPageAgain: false)
        view.fitPage()
        try await turn(-1, to: first)
        UserDefaults.standard.set([1.2, 200.0, 300.0], forKey: "viewport-\(id)-\(second)")
        try await turn(1, to: second, canPageAgain: false)
        view.fitPage()
        try await turn(-1, to: first)
        session.canvas.setZoomScale(session.canvas.minimumZoomScale * 1.8, animated: false)
        view.savePosition()
        XCTAssertFalse(view.pageTurn.shouldBegin(velocity: CGPoint(x: -300, y: 0)))
        let oldGesture = view.pageTurn.gesture
        window.rootViewController = nil; host = nil
        try await waitUntil { oldGesture.view == nil }
        host = UIHostingController(rootView: EditorScreen(store: store, noteID: id, session: session))
        window.rootViewController = host
        try await waitUntil { !session.busy && session.canvas.superview is PageScrollView && session.canvas.superview !== view }
        let reopened = try XCTUnwrap(session.canvas.superview as? PageScrollView)
        XCTAssertGreaterThan(session.canvas.zoomScale, session.canvas.minimumZoomScale)
        XCTAssertFalse(reopened.pageTurn.shouldBegin(velocity: CGPoint(x: -300, y: 0)))
        reopened.fitPage()
        try await waitUntil { abs(session.canvas.zoomScale - session.canvas.minimumZoomScale) < 0.02 }
        try await waitUntil { reopened.pageTurn.shouldBegin(velocity: CGPoint(x: -300, y: 0)) }
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<150 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Pagination did not reach an interactive installed page within 3 seconds", file: file, line: line)
        throw CocoaError(.userCancelled)
    }
}

private final class PaginationPan: UIPanGestureRecognizer {
    var phase = UIGestureRecognizer.State.possible
    var offset = CGPoint.zero
    var speed = CGPoint.zero
    override var state: UIGestureRecognizer.State { get { phase } set { phase = newValue } }
    override func translation(in view: UIView?) -> CGPoint { offset }
    override func velocity(in view: UIView?) -> CGPoint { speed }
}
