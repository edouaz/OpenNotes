import XCTest
@testable import OpenNotes

@MainActor
final class LassoAnchoringTests: XCTestCase {
    private func makeSelection() throws -> (PageScrollView, PageSelectionView) {
        let view = PageScrollView(canvas: InkCanvasView())
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        view.pageSize = CGSize(width: 800, height: 800); view.layoutIfNeeded()
        view.configureSelection(true, immediate: false, selected: nil)
        let selection = try XCTUnwrap(view.subviews.compactMap { $0 as? PageSelectionView }.first)
        return (view, selection)
    }

    /// The selected region must stay glued to the same page content when the viewport zooms and scrolls.
    func testSelectionFollowsZoomAndScroll() throws {
        let (view, selection) = try makeSelection()
        selection.follow(zoom: 1, offset: CGPoint(x: 0, y: 0))
        selection.installSelection(UIBezierPath(rect: CGRect(x: 100, y: 100, width: 100, height: 50)))
        // Page rect (100,100,100,50) at zoom 1, offset 0. Zoom to 2 with the offset (50, 20).
        selection.follow(zoom: 2, offset: CGPoint(x: 50, y: 20))
        let bounds = selection.selectionBounds
        XCTAssertEqual(bounds.minX, 100 * 2 - 50, accuracy: 0.001)
        XCTAssertEqual(bounds.minY, 100 * 2 - 20, accuracy: 0.001)
        XCTAssertEqual(bounds.width, 200, accuracy: 0.001)
        XCTAssertEqual(bounds.height, 100, accuracy: 0.001)
        // And back: the round trip lands on the original rectangle.
        selection.follow(zoom: 1, offset: .zero)
        XCTAssertEqual(selection.selectionBounds.minX, 100, accuracy: 0.001)
        XCTAssertEqual(selection.selectionBounds.width, 100, accuracy: 0.001)
        _ = view
    }

    func testHandlesAppearOnlyInManipulationMode() throws {
        let (_, selection) = try makeSelection()
        selection.installSelection(UIBezierPath(rect: CGRect(x: 80, y: 80, width: 160, height: 160)))
        XCTAssertFalse(selection.showsResizeHandles, "A plain selection shows no handles")
        selection.enterManipulation()
        XCTAssertTrue(selection.showsResizeHandles)
        selection.clearSelection()
        XCTAssertFalse(selection.showsResizeHandles, "Manipulation never outlives its selection")
    }
}
