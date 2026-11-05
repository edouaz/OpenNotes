import XCTest
import UIKit
@testable import OpenNotes

@MainActor
final class StickyActionTests: XCTestCase {
    func testDuplicateRotatedCollapsedNoteAtPageEdgesPreservesGeometryAndStacking() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "sticky-edge-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root); await store.load()
        let created = await store.create()
        let editor = EditorSession(store: store, noteID: try XCTUnwrap(created), preferences: preferences); await editor.open()
        let page = try XCTUnwrap(editor.page)
        let size = PageRenderer.size(page)
        var note = PageElement(kind: .stickyNote, x: 0, y: 0, width: size.width, height: size.height, text: "Edge")
        note.rotation = .pi / 4; note.collapsed = true; note.zIndex = 3
        var child = PageElement(kind: .text, x: 10, y: 10, width: 30, height: 30, text: "Child")
        child.parentID = note.id; child.zIndex = -1
        let applied = await editor.apply(.init(pageID: page.id, kind: .setElements, elements: [note, child]))
        XCTAssertTrue(applied)
        let duplicated = await editor.stickyAction(.duplicateSelection, id: note.id)
        XCTAssertTrue(duplicated)
        let elements = try XCTUnwrap(editor.page?.elements)
        let copy = try XCTUnwrap(elements.first { $0.text == "Edge" && $0.id != note.id })
        let copiedChild = try XCTUnwrap(elements.first { $0.text == "Child" && $0.id != child.id })
        XCTAssertEqual(copy.x, note.x); XCTAssertEqual(copy.y, note.y)
        XCTAssertEqual(copy.width, note.width); XCTAssertEqual(copy.height, note.height)
        XCTAssertEqual(copy.rotation, note.rotation); XCTAssertEqual(copy.collapsed, true)
        XCTAssertEqual(copiedChild.parentID, copy.id)
        XCTAssertLessThan(try XCTUnwrap(copiedChild.zIndex), try XCTUnwrap(copy.zIndex))
    }

    func testExactStickyActionsPreserveOverlapAndAttachments() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "sticky-actions-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root); await store.load()
        let created = await store.create()
        let noteID = try XCTUnwrap(created)
        let editor = EditorSession(store: store, noteID: noteID, preferences: preferences); await editor.open()
        let pageID = try XCTUnwrap(editor.page?.id)
        var back = PageElement(kind: .stickyNote, x: 100, y: 100, width: 160, height: 160, text: "Back")
        back.collapsed = true
        let front = PageElement(kind: .stickyNote, x: 100, y: 100, width: 160, height: 160, text: "Front")
        var child = PageElement(kind: .text, x: 120, y: 120, width: 60, height: 30, text: "Child")
        child.parentID = back.id
        let applied = await editor.apply(.init(pageID: pageID, kind: .setElements, elements: [back, child, front]))
        XCTAssertTrue(applied)
        let undo = try XCTUnwrap(editor.canvas.undoManager); undo.groupsByEvent = false
        let before = editor.page?.elements
        undo.beginUndoGrouping()
        let duplicated = await editor.stickyAction(.duplicateSelection, id: back.id)
        undo.endUndoGrouping(); XCTAssertTrue(duplicated)
        let elements = try XCTUnwrap(editor.page?.elements)
        XCTAssertEqual(elements.count, 5)
        let copied = try XCTUnwrap(elements.first { $0.kind == .stickyNote && $0.text == "Back" && $0.id != back.id })
        XCTAssertEqual(copied.collapsed, true)
        XCTAssertEqual(elements.filter { $0.text == "Front" }.count, 1)
        XCTAssertEqual(elements.first { $0.text == "Child" && $0.id != child.id }?.parentID, copied.id)
        undo.undo(); XCTAssertEqual(editor.page?.elements, before)

        undo.beginUndoGrouping()
        let brought = await editor.stickyAction(.bringFront, id: back.id)
        undo.endUndoGrouping()
        XCTAssertTrue(brought)
        let ordered = try XCTUnwrap(editor.page?.elements)
        XCTAssertEqual(ordered.map(\.id), [front.id, back.id, child.id])
        undo.beginUndoGrouping()
        let locked = await editor.stickyAction(.lockSelection, id: back.id)
        undo.endUndoGrouping()
        XCTAssertTrue(locked)
        XCTAssertEqual(editor.page?.elements?.first { $0.id == child.id }?.isLocked, true)
        let blocked = await editor.stickyAction(.duplicateSelection, id: back.id)
        XCTAssertFalse(blocked)
        undo.beginUndoGrouping()
        let unlocked = await editor.stickyAction(.lockSelection, id: back.id)
        undo.endUndoGrouping()
        XCTAssertTrue(unlocked)
        XCTAssertEqual(editor.page?.elements?.first { $0.id == child.id }?.isLocked, false)
        XCTAssertNil(editor.page?.elements?.first { $0.id == front.id }?.isLocked)
    }
}
