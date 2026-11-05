import XCTest
import UIKit
@testable import OpenNotes

@MainActor
final class StickyCompatibilityTests: XCTestCase {
    func testInsertionKeepsTheActiveWritingTool() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "sticky-insertion-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root); await store.load()
        let created = await store.create()
        let noteID = try XCTUnwrap(created)
        let session = EditorSession(store: store, noteID: noteID, preferences: preferences)
        await session.open()
        session.selectedTool = .fountainPen
        session.stickyInsertionColor = "#FFE66D"
        let inserted = await session.insertSticky(at: CGPoint(x: 100, y: 100))
        XCTAssertTrue(inserted)
        XCTAssertNil(session.stickyInsertionColor)
        XCTAssertEqual(session.selectedTool, .fountainPen)
        XCTAssertEqual(session.page?.elements?.last?.kind, .stickyNote)
    }

    func testAppearanceIsValidatedAtDocumentBoundary() throws {
        let page = NotePage(noteID: UUID(), index: 0, format: .a4Portrait, template: .blank, drawingResourceID: "ink.drawing")
        var note = PageElement(kind: .stickyNote)
        note.stickyCornerRadius = 16; note.stickyOpacity = 0.5; note.stickyShadow = 0.12
        XCTAssertNoThrow(try DocumentAction(pageID: page.id, kind: .upsertElement, element: note).applying(to: page))
        for bad in [-1.0, 25, .infinity, .nan] {
            note.stickyCornerRadius = bad
            XCTAssertThrowsError(try DocumentAction(pageID: page.id, kind: .upsertElement, element: note).applying(to: page))
        }
        note.stickyCornerRadius = 16
        note.stickyOpacity = 1.1
        XCTAssertThrowsError(try DocumentAction(pageID: page.id, kind: .upsertElement, element: note).applying(to: page))
        note.stickyOpacity = 0.5; note.stickyShadow = 0.31
        XCTAssertThrowsError(try DocumentAction(pageID: page.id, kind: .upsertElement, element: note).applying(to: page))
    }

    func testSelectingNotesIsExclusiveAndSurvivesModelRefresh() throws {
        let view = PageScrollView(canvas: InkCanvasView())
        defer { view.detachInteractions(); view.pageTurn.detach() }
        var page = NotePage(noteID: UUID(), index: 0, format: .a4Portrait, template: .blank, drawingResourceID: "ink.drawing")
        let a = PageElement(kind: .stickyNote, x: 50, y: 50)
        var b = PageElement(kind: .stickyNote, x: 300, y: 50)
        page.elements = [a, b]; view.pageSize = PageRenderer.size(page)
        view.configureNotes(page, edit: nil) { _, _ in }
        view.selectNote(a.id)
        var controls = view.subviews.compactMap { $0 as? StickyNoteControl }
        XCTAssertEqual(controls.filter(\.isObjectSelected).map { $0.item.id }, [a.id])
        try XCTUnwrap(controls.first { $0.item.id == b.id }).setObjectSelected(true)
        XCTAssertEqual(view.selectedNoteID, b.id)
        XCTAssertEqual(controls.filter(\.isObjectSelected).map { $0.item.id }, [b.id])
        b.stickyCornerRadius = 16; page.elements = [a, b]
        view.configureNotes(page, edit: nil) { _, _ in }
        controls = view.subviews.compactMap { $0 as? StickyNoteControl }
        XCTAssertEqual(controls.filter(\.isObjectSelected).map { $0.item.id }, [b.id])
        view.noteBodySelectionEnabled = false
        XCTAssertNil(view.selectedNoteID)
        XCTAssertTrue(controls.allSatisfy { !$0.isObjectSelected && !$0.allowsBodySelection })
        view.noteInteractionEnabled = false
        XCTAssertTrue(controls.allSatisfy { !$0.isUserInteractionEnabled })
    }

    func testLassoOverlayDoesNotBlockNoteControls() throws {
        let view = PageScrollView(canvas: InkCanvasView())
        defer { view.detachInteractions(); view.pageTurn.detach() }
        view.frame = CGRect(x: 0, y: 0, width: 794, height: 1123)
        view.pageSize = view.bounds.size; view.needsFit = false
        view.canvas.frame = view.bounds; view.canvas.zoomScale = 1
        var page = NotePage(noteID: UUID(), index: 0, format: .a4Portrait, template: .blank, drawingResourceID: "ink.drawing")
        let note = PageElement(kind: .stickyNote, x: 100, y: 100)
        page.elements = [note]
        view.fingerScrollsSelection = true
        view.configureSelection(true, immediate: false, selected: nil)
        view.configureNotes(page, edit: nil) { _, _ in }
        view.selectNote(note.id)
        let control = try XCTUnwrap(view.subviews.compactMap { $0 as? StickyNoteControl }.first)
        control.layoutIfNeeded()
        let point = control.resizeHandle.convert(CGPoint(x: 22, y: 22), to: view)
        XCTAssertTrue(view.hitTest(point, with: nil) === control.resizeHandle)
    }

    func testCollapsedContentIncludesNestedDescendants() {
        var note = PageElement(kind: .stickyNote)
        note.collapsed = true
        var child = PageElement(kind: .rectangle)
        child.parentID = note.id
        var nested = PageElement(kind: .text, text: "Hidden nested text")
        nested.parentID = child.id
        var page = NotePage(noteID: UUID(), index: 0, format: .a4Portrait, template: .blank, drawingResourceID: "ink.drawing")
        page.elements = [note, child, nested]
        XCTAssertEqual(page.collapsedContentParents, Set([note.id, child.id, nested.id]))
        note.collapsed = false; page.elements = [note, child, nested]
        XCTAssertTrue(page.collapsedContentParents.isEmpty)
    }

    func testCollapsedDescendantNotesHaveNoInteractionOverlay() {
        let view = PageScrollView(canvas: InkCanvasView())
        defer { view.detachInteractions(); view.pageTurn.detach() }
        var parent = PageElement(kind: .stickyNote)
        parent.collapsed = true
        var child = PageElement(kind: .stickyNote)
        child.parentID = parent.id
        var page = NotePage(noteID: UUID(), index: 0, format: .a4Portrait, template: .blank, drawingResourceID: "ink.drawing")
        page.elements = [parent, child]; view.pageSize = PageRenderer.size(page)
        view.configureNotes(page, edit: nil) { _, _ in }
        XCTAssertEqual(view.subviews.compactMap { ($0 as? StickyNoteControl)?.item.id }, [parent.id])
    }

    func testChildLockRefreshDisablesParentManipulation() throws {
        let view = PageScrollView(canvas: InkCanvasView())
        defer { view.detachInteractions(); view.pageTurn.detach() }
        let parent = PageElement(kind: .stickyNote)
        var child = PageElement(kind: .rectangle)
        child.parentID = parent.id
        var page = NotePage(noteID: UUID(), index: 0, format: .a4Portrait, template: .blank, drawingResourceID: "ink.drawing")
        page.elements = [parent, child]; view.pageSize = PageRenderer.size(page)
        view.configureNotes(page, edit: nil) { _, _ in }
        XCTAssertTrue(try XCTUnwrap(view.subviews.compactMap { $0 as? StickyNoteControl }.first).canManipulate)
        child.isLocked = true; page.elements = [parent, child]
        view.configureNotes(page, edit: nil) { _, _ in }
        XCTAssertFalse(try XCTUnwrap(view.subviews.compactMap { $0 as? StickyNoteControl }.first).canManipulate)
    }

    func testRoundedBodyHitTestingMatchesItsSilhouette() {
        var note = PageElement(kind: .stickyNote)
        note.stickyCornerRadius = 16
        let control = StickyNoteControl(item: note)
        control.frame = CGRect(x: 0, y: 0, width: 220, height: 180)
        control.layoutIfNeeded()
        XCTAssertNil(control.hitTest(CGPoint(x: 1, y: 1), with: nil))
        XCTAssertTrue(control.hitTest(CGPoint(x: 110, y: 90), with: nil) === control)
    }

    func testResizeAtLowZoomDoesNotEnlargeSmallNotes() {
        let note = PageElement(kind: .stickyNote, x: 20, y: 20, width: 100, height: 100)
        let control = StickyNoteControl(item: note)
        control.pageSize = CGSize(width: 794, height: 1123); control.zoom = 0.25
        let resized = control.resizedItem(to: CGSize(width: 101, height: 100))
        XCTAssertEqual(resized.width, 101)
        XCTAssertEqual(resized.height, 100)
    }
}
