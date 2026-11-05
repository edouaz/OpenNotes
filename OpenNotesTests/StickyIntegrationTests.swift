import XCTest
import UIKit
@testable import OpenNotes

@MainActor
final class StickyIntegrationTests: XCTestCase {
    private func stroke(from start: CGPoint, to end: CGPoint) -> InkStroke {
        let points = [start, end].enumerated().map { index, point in
            InkStrokePoint(location: point, timeOffset: Double(index) / 120,
                           size: CGSize(width: 4, height: 4), opacity: 1, force: 0.5, azimuth: 0, altitude: 1)
        }
        return InkStroke(ink: InkInk(.pen, color: .blue), path: InkStrokePath(controlPoints: points, creationDate: Date(timeIntervalSinceReferenceDate: 1)), style: InkStyle(width: 4))
    }
    private func assertPosition(_ stroke: InkStroke, x: CGFloat, y: CGFloat, file: StaticString = #filePath, line: UInt = #line) throws {
        let point = try XCTUnwrap(stroke.path.first, file: file, line: line).location.applying(stroke.transform)
        XCTAssertEqual(point.x, x, accuracy: 0.00001, file: file, line: line)
        XCTAssertEqual(point.y, y, accuracy: 0.00001, file: file, line: line)
    }
    func testNewStickyInkIsClippedWithoutChangingSourceSamples() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "sticky-clipping-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let session = EditorSession(store: LibraryStore(root: root), noteID: UUID(), preferences: preferences)
        var page = NotePage(noteID: session.noteID, index: 0, format: .a4Portrait, template: .blank, drawingResourceID: "ink.drawing")
        let note = PageElement(kind: .stickyNote, x: 100, y: 100, width: 100, height: 100)
        page.elements = [note]; session.page = page
        let source = stroke(from: CGPoint(x: 120, y: 140), to: CGPoint(x: 250, y: 140))
        let clipped = try XCTUnwrap(session.attachingInk(InkDrawing(strokes: [source])).strokes.first)
        XCTAssertEqual(clipped.parentID, note.id)
        XCTAssertEqual(clipped.path.controlPoints, source.path.controlPoints)
        XCTAssertGreaterThan(clipped.renderBounds.maxX, note.visibleBounds.maxX)
        let visible = try XCTUnwrap(InkDrawing(strokes: [clipped]).visible(on: page).strokes.first)
        XCTAssertLessThanOrEqual(visible.renderBounds.maxX, note.visibleBounds.maxX + 0.01)
        XCTAssertEqual(try InkDrawing(data: InkDrawing(strokes: [clipped]).encodedData()).strokes.first?.vectorOutline, clipped.vectorOutline)
    }
    func testResizingStickyClipsWithoutChangingStoredInkOrChildSize() throws {
        let session = EditorSession(store: LibraryStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), noteID: UUID())
        var note = PageElement(kind: .stickyNote, x: 100, y: 100, width: 200, height: 100)
        var child = PageElement(kind: .text, x: 115, y: 120, width: 60, height: 30, text: "Preserved")
        child.parentID = note.id
        var original = stroke(from: CGPoint(x: 120, y: 140), to: CGPoint(x: 270, y: 140))
        original.parentID = note.id
        session.drawing = InkDrawing(strokes: [original])
        var page = NotePage(noteID: session.noteID, index: 0, format: .a4Portrait, template: .blank, drawingResourceID: "ink.drawing")
        page.elements = [note, child]; session.page = page
        let before = try session.drawing.encodedData()
        let previous = [note, child]
        note.width = 80
        let children = session.reconcileStickyElements([note, child], previous: previous)
        let resized = session.reconcileStickyInk(session.drawing, previous: previous, updated: children)
        XCTAssertEqual(try resized.encodedData(), before)
        XCTAssertEqual(children.first { $0.id == child.id }?.width, child.width)
        page.elements = children
        let clipped = try XCTUnwrap(resized.visible(on: page).strokes.first)
        XCTAssertLessThanOrEqual(clipped.renderBounds.maxX, 180.01)
        note.width = 200; page.elements = [note, child]
        XCTAssertGreaterThan(try XCTUnwrap(resized.visible(on: page).strokes.first).renderBounds.maxX, 260)
    }

    func testResizePreviewClipsAndRevealsInkWithoutScaling() throws {
        var note = PageElement(kind: .stickyNote, x: 100, y: 100, width: 200, height: 100)
        var page = NotePage(noteID: UUID(), index: 0, format: .a4Portrait, template: .blank, drawingResourceID: "ink.drawing")
        page.width = 400; page.height = 400; page.elements = [note]
        var ink = stroke(from: CGPoint(x: 120, y: 140), to: CGPoint(x: 270, y: 140)); ink.parentID = note.id
        let drawing = InkDrawing(strokes: [ink])
        let snapshot = SelectionMoveSnapshot(page: page, drawing: drawing, path: UIBezierPath(rect: note.visibleBounds), settings: EditorToolSettings())
        let preview = SelectionDragPreview(frame: CGRect(x: 0, y: 0, width: 400, height: 400), page: page, artwork: nil, drawing: drawing, snapshot: snapshot, zoom: 1, offset: .zero)
        preview.beginStickyResize(note: note, page: page, artwork: nil)
        func pixel() throws -> [UInt8] {
            let image = UIGraphicsImageRenderer(size: preview.bounds.size).image { preview.layer.render(in: $0.cgContext) }
            let cg = try XCTUnwrap(image.cgImage)
            var bytes = [UInt8](repeating: 0, count: 4)
            let context = try XCTUnwrap(CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.translateBy(x: -240, y: -260)
            context.draw(cg, in: CGRect(origin: .zero, size: preview.bounds.size))
            return bytes
        }
        preview.resizeSticky(to: CGSize(width: 80, height: 100))
        preview.layoutIfNeeded(); let small = try pixel()
        note.width = 200; preview.resizeSticky(to: CGSize(width: note.width, height: note.height))
        preview.layoutIfNeeded(); let large = try pixel()
        XCTAssertNotEqual(small, large, "Expanding the frame should reveal the original ink")
        XCTAssertGreaterThan(large[2], large[0], "The expanded frame reveals the blue ink at its original position")
    }

    func testCaptureSnapshotIncludesUncommittedStickyText() throws {
        let suite = "sticky-capture-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let store = LibraryStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(suite))
        let session = EditorSession(store: store, noteID: UUID(), preferences: preferences)
        var page = NotePage(noteID: session.noteID, index: 0, format: .a4Portrait, template: .blank, drawingResourceID: "ink.drawing")
        var note = PageElement(kind: .stickyNote, text: "Before")
        page.elements = [note]; session.page = page
        note.text = "Current draft"
        session.stageStickyEdit(note)
        XCTAssertEqual(session.pageIncludingDrafts?.elements?.first?.text, "Current draft")
        XCTAssertEqual(session.page?.elements?.first?.text, "Before")
    }
    func testStickyTapStartsIndependentTextEditingAndRestoresDrawing() throws {
        let canvas = InkCanvasView()
        let view = PageScrollView(canvas: canvas)
        defer { view.detachInteractions(); view.pageTurn.detach() }
        var page = NotePage(noteID: UUID(), index: 0, format: .a4Portrait, template: .blank, drawingResourceID: "ink.drawing")
        page.elements = [PageElement(kind: .stickyNote, x: 50, y: 50, width: 200, height: 180)]
        view.pageSize = PageRenderer.size(page)
        view.configureNotes(page, edit: nil) { _, _ in }
        let control = try XCTUnwrap(view.subviews.compactMap { $0 as? StickyNoteControl }.first)
        XCTAssertFalse(control.isAccessibilityElement)
        view.updateAccessibilityElements()
        XCTAssertTrue(view.accessibilityElements?.contains(where: { ($0 as? UIView) === control }) == true)
        canvas.drawingGestureRecognizer.isEnabled = true
        control.sendActions(for: .touchUpInside)
        XCTAssertFalse(control.isEditingInline)
        control.textButton.sendActions(for: .touchUpInside)
        XCTAssertTrue(control.isEditingInline)
        XCTAssertEqual(view.editingInlineNoteID, control.item.id)
        XCTAssertFalse(canvas.drawingGestureRecognizer.isEnabled)
        let editor = try XCTUnwrap(control.subviews.compactMap { $0 as? UITextView }.first)
        XCTAssertNotNil(editor.typingAttributes[.font])
        control.endInlineEditing()
        XCTAssertNil(view.editingInlineNoteID)
        XCTAssertTrue(canvas.drawingGestureRecognizer.isEnabled)
    }
    func testAttachedInkFollowsMoveRotationResizeCollapseUndoRedoAndReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "sticky-integration-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root); await store.load()
        let created = await store.create(), noteID = try XCTUnwrap(created)
        let editor = EditorSession(store: store, noteID: noteID, preferences: preferences); await editor.open()
        let pageID = try XCTUnwrap(editor.page?.id)
        let undo = try XCTUnwrap(editor.canvas.undoManager); undo.groupsByEvent = false
        var note = PageElement(kind: .stickyNote, x: 100, y: 100, width: 200, height: 100, text: "Attached")
        undo.beginUndoGrouping()
        let inserted = await editor.apply(.init(pageID: pageID, kind: .upsertElement, element: note))
        undo.endUndoGrouping(); XCTAssertTrue(inserted)
        undo.beginUndoGrouping()
        editor.replaceDrawing(InkDrawing(strokes: [stroke(from: CGPoint(x: 120, y: 130), to: CGPoint(x: 160, y: 130))]), actionName: "Draw")
        undo.endUndoGrouping()
        XCTAssertEqual(editor.drawing.strokes.first?.parentID, note.id)
        let attachedID = try XCTUnwrap(editor.drawing.strokes.first?.id)
        let attachedBytes = try editor.drawing.encodedData()
        note.x += 80; note.y += 40
        undo.beginUndoGrouping()
        let moved = await editor.apply(.init(pageID: pageID, kind: .upsertElement, element: note))
        undo.endUndoGrouping(); XCTAssertTrue(moved)
        try assertPosition(XCTUnwrap(editor.drawing.strokes.first), x: 200, y: 170)
        let movedBytes = try editor.drawing.encodedData()
        undo.undo(); XCTAssertEqual(try editor.drawing.encodedData(), attachedBytes)
        XCTAssertEqual(editor.page?.elements?.first?.x, 100)
        undo.redo(); XCTAssertEqual(try editor.drawing.encodedData(), movedBytes)
        XCTAssertEqual(editor.page?.elements?.first?.x, 180)
        note.rotation = .pi / 2
        undo.beginUndoGrouping()
        let rotated = await editor.apply(.init(pageID: pageID, kind: .upsertElement, element: note))
        undo.endUndoGrouping(); XCTAssertTrue(rotated)
        try assertPosition(XCTUnwrap(editor.drawing.strokes.first), x: 300, y: 110)
        let rotatedBytes = try editor.drawing.encodedData()
        undo.undo(); XCTAssertEqual(try editor.drawing.encodedData(), movedBytes)
        undo.redo(); XCTAssertEqual(try editor.drawing.encodedData(), rotatedBytes)
        note.width = 400; note.height = 200
        undo.beginUndoGrouping()
        let resized = await editor.apply(.init(pageID: pageID, kind: .upsertElement, element: note))
        undo.endUndoGrouping(); XCTAssertTrue(resized)
        try assertPosition(XCTUnwrap(editor.drawing.strokes.first), x: 450, y: 60)
        let expandedDrawing = try editor.drawing.encodedData()
        note.collapsed = true
        undo.beginUndoGrouping()
        let collapsed = await editor.apply(.init(pageID: pageID, kind: .upsertElement, element: note))
        undo.endUndoGrouping(); XCTAssertTrue(collapsed)
        let collapsedDrawing = try editor.drawing.encodedData()
        XCTAssertEqual(editor.drawing.strokes.count, 1)
        XCTAssertEqual(editor.drawing.visible(on: try XCTUnwrap(editor.page)).strokes.count, 0)
        undo.undo()
        XCTAssertEqual(editor.page?.elements?.first?.collapsed, nil)
        XCTAssertEqual(try editor.drawing.encodedData(), expandedDrawing)
        XCTAssertEqual(editor.drawing.visible(on: try XCTUnwrap(editor.page)).strokes.count, 1)
        undo.redo()
        XCTAssertEqual(editor.page?.elements?.first?.collapsed, true)
        XCTAssertEqual(try editor.drawing.encodedData(), collapsedDrawing)
        let saved = await editor.flush(); XCTAssertTrue(saved)
        let reopenedStore = LibraryStore(root: root); await reopenedStore.load()
        let reopened = EditorSession(store: reopenedStore, noteID: noteID, preferences: preferences); await reopened.open(pageID)
        XCTAssertNil(reopened.error)
        XCTAssertEqual(reopened.page?.elements, [note])
        XCTAssertEqual(reopened.drawing.strokes.first?.id, attachedID)
        XCTAssertEqual(reopened.drawing.strokes.first?.parentID, note.id)
        XCTAssertEqual(try reopened.drawing.encodedData(), collapsedDrawing)
        XCTAssertTrue(reopened.drawing.visible(on: try XCTUnwrap(reopened.page)).strokes.isEmpty)
        try assertPosition(XCTUnwrap(reopened.drawing.strokes.first), x: 450, y: 60)
    }
    func testInlineDraftCallbackPreservesPageFontSizeBeforeFocusEnds() throws {
        let note = PageElement(kind: .stickyNote, text: "Before")
        let control = StickyNoteControl(item: note); control.zoom = 2
        let editor = UITextView()
        editor.attributedText = NSAttributedString(string: "Draft before switching tabs 👋", attributes: [.font: UIFont.boldSystemFont(ofSize: 32)])
        var captured: PageElement?
        control.draftChanged = { captured = $0 }
        control.textViewDidChange(editor)
        let draft = try XCTUnwrap(captured)
        XCTAssertEqual(draft.text, editor.text)
        XCTAssertEqual(control.item, note, "The focused view retains its original snapshot while the session stages the draft")
        let text = try RichTextDocument.decode(XCTUnwrap(draft.richTextRTF))
        XCTAssertEqual((text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.pointSize, 16)
    }
    func testHierarchyRejectsCyclesAndParentDeletionRemovesDescendants() throws {
        let page = NotePage(noteID: UUID(), index: 0, format: .a4Portrait, template: .blank, drawingResourceID: "ink.drawing")
        var parent = PageElement(kind: .stickyNote)
        var child = PageElement(kind: .text)
        var grandchild = PageElement(kind: .image)
        grandchild.resource = "sample.png"
        child.parentID = parent.id; grandchild.parentID = child.id
        let unrelated = PageElement(kind: .text, text: "Keep this")
        let tree = try DocumentAction(pageID: page.id, kind: .setElements, elements: [parent, child, grandchild, unrelated]).applying(to: page)
        let deleted = try DocumentAction(pageID: page.id, kind: .removeElement, elementID: parent.id).applying(to: tree)
        XCTAssertEqual(deleted.elements, [unrelated])
        parent.parentID = grandchild.id
        XCTAssertFalse(DocumentAction.validHierarchy([parent, child, grandchild]))
        XCTAssertThrowsError(try DocumentAction(pageID: page.id, kind: .setElements, elements: [parent, child, grandchild]).applying(to: page))
        parent.parentID = parent.id
        XCTAssertThrowsError(try DocumentAction(pageID: page.id, kind: .upsertElement, element: parent).applying(to: page))
    }
    func testInsertedTextAndImageAttachAndFollowStickyMove() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "sticky-elements-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root); await store.load()
        let created = await store.create(), noteID = try XCTUnwrap(created)
        let editor = EditorSession(store: store, noteID: noteID, preferences: preferences); await editor.open()
        let pageID = try XCTUnwrap(editor.page?.id)
        let undo = try XCTUnwrap(editor.canvas.undoManager); undo.groupsByEvent = false
        var parent = PageElement(kind: .stickyNote, x: 100, y: 100, width: 300, height: 200, text: "Parent")
        undo.beginUndoGrouping()
        let inserted = await editor.apply(.init(pageID: pageID, kind: .upsertElement, element: parent))
        undo.endUndoGrouping(); XCTAssertTrue(inserted)
        let text = PageElement(kind: .text, x: 120, y: 140, width: 100, height: 40, text: "Attached text")
        undo.beginUndoGrouping()
        let addedText = await editor.apply(.init(pageID: pageID, kind: .upsertElement, element: text))
        undo.endUndoGrouping(); XCTAssertTrue(addedText)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { context in UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 10, height: 10)) }
        try await store.disk.write(XCTUnwrap(image.pngData()), name: "attached.png")
        var photo = PageElement(kind: .image, x: 250, y: 180, width: 60, height: 40)
        photo.resource = "attached.png"
        undo.beginUndoGrouping()
        let addedImage = await editor.apply(.init(pageID: pageID, kind: .upsertElement, element: photo))
        undo.endUndoGrouping(); XCTAssertTrue(addedImage)
        XCTAssertEqual(editor.page?.elements?.first(where: { $0.id == text.id })?.parentID, parent.id)
        XCTAssertEqual(editor.page?.elements?.first(where: { $0.id == photo.id })?.parentID, parent.id)
        let before = editor.page?.elements
        parent.x += 50; parent.y += 60
        undo.beginUndoGrouping()
        let moved = await editor.apply(.init(pageID: pageID, kind: .upsertElement, element: parent))
        undo.endUndoGrouping(); XCTAssertTrue(moved)
        let movedText = try XCTUnwrap(editor.page?.elements?.first(where: { $0.id == text.id }))
        let movedImage = try XCTUnwrap(editor.page?.elements?.first(where: { $0.id == photo.id }))
        XCTAssertEqual(movedText.x, 170, accuracy: 0.00001); XCTAssertEqual(movedText.y, 200, accuracy: 0.00001)
        XCTAssertEqual(movedImage.x, 300, accuracy: 0.00001); XCTAssertEqual(movedImage.y, 240, accuracy: 0.00001)
        let after = editor.page?.elements
        undo.undo(); XCTAssertEqual(editor.page?.elements, before)
        undo.redo(); XCTAssertEqual(editor.page?.elements, after)
        let saved = await editor.flush(); XCTAssertTrue(saved)
        let reopenedStore = LibraryStore(root: root); await reopenedStore.load()
        let reopened = EditorSession(store: reopenedStore, noteID: noteID, preferences: preferences); await reopened.open(pageID)
        XCTAssertEqual(reopened.page?.elements, after)
        XCTAssertNotNil(reopened.resources["attached.png"])
    }
    func testTransparentStickyInteractionViewPreservesSharedPageRendering() throws {
        var page = NotePage(noteID: UUID(), index: 0, format: .a4Portrait, template: .blank, drawingResourceID: "ink.drawing")
        var note = PageElement(kind: .stickyNote, x: 40, y: 50, width: 200, height: 140, text: "Shared rendering")
        note.fillColorHex = "#CCEEFF"
        page.elements = [note]
        let baseline = PageRenderer.image(page, data: nil, drawing: InkDrawing(), scale: 1)
        let control = StickyNoteControl(item: note)
        control.frame = CGRect(x: 0, y: 0, width: note.width, height: note.height)
        control.collapseButton.isHidden = true; control.resizeHandle.isHidden = true
        control.dragHandle.isHidden = true; control.textButton.isHidden = true
        control.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let visible = UIGraphicsImageRenderer(size: PageRenderer.size(page), format: format).image { output in
            baseline.draw(at: .zero)
            output.cgContext.translateBy(x: note.x, y: note.y)
            control.layer.render(in: output.cgContext)
        }
        XCTAssertEqual(baseline.pngData(), visible.pngData(), "Interaction overlays must not redraw the sticky body above the ink")
        control.textButton.sendActions(for: .touchUpInside)
        let editor = try XCTUnwrap(control.subviews.compactMap { $0 as? UITextView }.first)
        XCTAssertEqual(editor.frame, control.bounds, "Inline editor must cover the original static text")
        XCTAssertEqual(editor.backgroundColor, UIColor.clear, "The shared renderer owns the appearance while text editing stays transparent")
        control.textViewDidEndEditing(editor)
    }
    func testAlignmentFormatsWholeParagraphAndPreservesSelection() {
        let view = UITextView()
        view.attributedText = NSAttributedString(string: "first word\nsecond line", attributes: [.font: UIFont.systemFont(ofSize: 16)])
        view.selectedRange = NSRange(location: 2, length: 3)
        let formatting = RichTextFormatting(); formatting.view = view
        formatting.align(.right)
        XCTAssertEqual((view.attributedText.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.alignment, .right)
        XCTAssertEqual((view.attributedText.attribute(.paragraphStyle, at: 9, effectiveRange: nil) as? NSParagraphStyle)?.alignment, .right)
        XCTAssertNotEqual((view.attributedText.attribute(.paragraphStyle, at: 12, effectiveRange: nil) as? NSParagraphStyle)?.alignment, .right)
        XCTAssertEqual(view.selectedRange, NSRange(location: 2, length: 3))
    }
    func testReadOnlyBlocksDocumentDrawingClearAndPasteMutations() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "readonly-integration-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root); await store.load()
        let created = await store.create(), noteID = try XCTUnwrap(created)
        let editor = EditorSession(store: store, noteID: noteID, preferences: preferences); await editor.open()
        let page = try XCTUnwrap(editor.page)
        let original = stroke(from: CGPoint(x: 30, y: 40), to: CGPoint(x: 100, y: 40))
        let undo = try XCTUnwrap(editor.canvas.undoManager); undo.groupsByEvent = false
        undo.beginUndoGrouping(); editor.replaceDrawing(InkDrawing(strokes: [original]), actionName: "Draw"); undo.endUndoGrouping()
        let saved = await editor.flush(); XCTAssertTrue(saved)
        let bytes = try editor.drawing.encodedData(), elements = editor.page?.elements
        undo.removeAllActions()
        editor.isReadOnly = true
        let applied = await editor.apply(.init(pageID: page.id, kind: .upsertElement, element: PageElement(kind: .stickyNote)))
        XCTAssertFalse(applied)
        editor.replaceDrawing(InkDrawing(), actionName: "Should be blocked")
        editor.replaceContent(InkDrawing(), elements: [], actionName: "Should be blocked")
        let cleared = await editor.clearPage(); XCTAssertFalse(cleared)
        await editor.paste(at: CGPoint(x: 50, y: 50))
        editor.stickyInsertionColor = "#FFEB80"
        let inserted = await editor.insertSticky(at: CGPoint(x: 50, y: 50)); XCTAssertFalse(inserted)
        XCTAssertEqual(try editor.drawing.encodedData(), bytes)
        XCTAssertEqual(editor.page?.elements, elements)
        XCTAssertFalse(undo.canUndo)
        let flushed = await editor.flush(); XCTAssertTrue(flushed)
        let reopened = EditorSession(store: store, noteID: noteID, preferences: preferences); await reopened.open(page.id)
        XCTAssertEqual(try reopened.drawing.encodedData(), bytes)
        XCTAssertEqual(reopened.page?.elements, elements)
    }
    func testInlineDraftAutosaveKeepsEditorAndReadOnlyCommitsLastKeystroke() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root); await store.load()
        let created = await store.create(); let id = try XCTUnwrap(created)
        let session = EditorSession(store: store, noteID: id); await session.open()
        let pageID = try XCTUnwrap(session.page?.id)
        let note = PageElement(kind: .stickyNote, text: "Initial")
        let inserted = await session.apply(.init(pageID: pageID, kind: .upsertElement, element: note))
        XCTAssertTrue(inserted)
        let view = PageScrollView(canvas: session.canvas)
        view.pageSize = PageRenderer.size(try XCTUnwrap(session.page))
        view.onNoteDraft = { session.stageStickyEdit($0) }
        view.configureNotes(try XCTUnwrap(session.page), edit: nil) { _, _ in }
        let control = try XCTUnwrap(view.subviews.compactMap { $0 as? StickyNoteControl }.first)
        control.beginInlineEditing()
        let textView = try XCTUnwrap(control.subviews.compactMap { $0 as? UITextView }.first)
        textView.attributedText = NSAttributedString(string: "Autosaved", attributes: [.font: UIFont.systemFont(ofSize: 16)])
        control.textViewDidChange(textView)
        let saved = await session.flush(); XCTAssertTrue(saved)
        view.configureNotes(try XCTUnwrap(session.page), edit: nil) { _, _ in }
        XCTAssertTrue(view.subviews.contains { $0 === control })
        XCTAssertTrue(control.isEditingInline)
        textView.attributedText = NSAttributedString(string: "Last character 😀", attributes: [.font: UIFont.systemFont(ofSize: 16)])
        control.textViewDidChange(textView)
        session.isReadOnly = true
        XCTAssertEqual(session.page?.elements?.first?.text, "Last character 😀")
        let flushed = await session.flush(); XCTAssertTrue(flushed)
        let reopened = EditorSession(store: store, noteID: id); await reopened.open(pageID)
        XCTAssertEqual(reopened.page?.elements?.first?.text, "Last character 😀")
        control.endInlineEditing()
    }

}
