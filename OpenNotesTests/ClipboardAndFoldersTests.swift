import XCTest
import UIKit
@testable import OpenNotes

@MainActor
final class ClipboardAndFoldersTests: XCTestCase {
    func testPastedInkGetsIndependentIDsAndCanBeSavedBesideOriginal() throws {
        let original = InkDrawing(strokes: [stroke(at: CGPoint(x: 20, y: 30))])
        let pasted = try DocumentClipboard.decodeInk(try original.encodedData(), at: CGPoint(x: 100, y: 100), pageSize: CGSize(width: 600, height: 800))
        XCTAssertNotEqual(pasted.strokes.first?.id, original.strokes.first?.id)
        let combined = InkDrawing(strokes: original.strokes + pasted.strokes)
        XCTAssertEqual(try InkDrawing(data: combined.encodedData()).strokes.count, 2)
    }
    func testFingerPasteCentersContentOnTheTouchAndStaysOnThePage() throws {
        let data = try InkDrawing(strokes: [stroke(at: CGPoint(x: 20, y: 30))]).encodedData()   // bounds ≈ 38 x 28
        let page = CGSize(width: 600, height: 800)
        let top = try DocumentClipboard.decodeInk(data, at: CGPoint(x: 300, y: 400), pageSize: page)
        let centered = try DocumentClipboard.decodeInk(data, at: CGPoint(x: 300, y: 400), pageSize: page, centered: true)
        XCTAssertEqual(centered.bounds.midX, 300, accuracy: 0.5); XCTAssertEqual(centered.bounds.midY, 400, accuracy: 0.5)
        XCTAssertEqual(top.bounds.minX, 300, accuracy: 0.5)
        let corner = try DocumentClipboard.decodeInk(data, at: .zero, pageSize: page, centered: true)
        XCTAssertGreaterThanOrEqual(corner.bounds.minX, 0); XCTAssertGreaterThanOrEqual(corner.bounds.minY, 0)
    }
    private func stroke(at origin: CGPoint) -> InkStroke {
        let points = [origin, CGPoint(x: origin.x + 30, y: origin.y + 20)].enumerated().map { index, point in
            InkStrokePoint(location: point, timeOffset: Double(index), size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return InkStroke(ink: InkInk(.pen, color: .red), path: InkStrokePath(controlPoints: points, creationDate: Date()))
    }
    func testInkCopySelectsOnlyInkAndPastesEditableAtRequestedPosition() throws {
        let source = InkDrawing(strokes: [stroke(at: CGPoint(x: 20, y: 30)), stroke(at: CGPoint(x: 400, y: 500))])
        let selected = DocumentClipboard.selectedInk(source, inside: UIBezierPath(rect: CGRect(x: 0, y: 0, width: 100, height: 100)))
        XCTAssertEqual(selected.strokes.count, 1)
        let pasted = try DocumentClipboard.decodeInk(selected.dataRepresentation(), at: CGPoint(x: 200, y: 300), pageSize: CGSize(width: 794, height: 1123))
        XCTAssertEqual(pasted.strokes.count, 1)
        XCTAssertEqual(pasted.bounds.minX, 200, accuracy: 1)
        XCTAssertEqual(pasted.bounds.minY, 300, accuracy: 1)
        XCTAssertEqual(pasted.strokes.first?.ink.inkType, .pen)
        let empty = DocumentClipboard.selectedInk(source, inside: UIBezierPath(rect: CGRect(x: 100, y: 100, width: 20, height: 20)))
        XCTAssertTrue(empty.strokes.isEmpty)
        XCTAssertThrowsError(try DocumentClipboard.decodeInk(Data("broken".utf8), at: .zero, pageSize: CGSize(width: 100, height: 100)))
    }
    func testEachImageCornerKeepsOppositeCornerAndAspectRatio() {
        for corner in 0..<4 {
            let item = PageElement(kind: .image, x: 200, y: 200, width: 200, height: 100)
            let view = ImageHandlesView(item: item, image: nil); view.pageSize = CGSize(width: 1000, height: 1000)
            view.resizeImage(by: 1.5, corner: corner)
            XCTAssertEqual(view.item.width / view.item.height, 2, accuracy: 0.001)
            if corner % 2 == 0 { XCTAssertEqual(view.item.x + view.item.width, 400, accuracy: 0.001) }
            else { XCTAssertEqual(view.item.x, 200) }
            if corner < 2 { XCTAssertEqual(view.item.y + view.item.height, 300, accuracy: 0.001) }
            else { XCTAssertEqual(view.item.y, 200) }
        }
    }
    func testImageAndRegionActionsAreAccessible() throws {
        let view = ImageHandlesView(item: PageElement(kind: .image, x: 100, y: 100, width: 200, height: 100), image: nil)
        view.pageSize = CGSize(width: 1000, height: 1000)
        XCTAssertTrue(view.isAccessibilityElement)
        let move = try XCTUnwrap(view.accessibilityCustomActions?.first { $0.name == "Move right" })
        XCTAssertTrue(try XCTUnwrap(move.actionHandler)(move))
        XCTAssertEqual(view.item.x, 120)
        let resize = try XCTUnwrap(view.accessibilityCustomActions?.first { $0.name == "Enlarge" })
        XCTAssertTrue(try XCTUnwrap(resize.actionHandler)(resize))
        XCTAssertEqual(view.item.width, 220, accuracy: 0.001)
        let region = PageSelectionView()
        XCTAssertTrue(region.isAccessibilityElement)
        XCTAssertEqual(region.accessibilityCustomActions?.map(\.name), ["Enlarge selection", "Shrink selection", "Delete selection", "Copy image", "Copy strokes", "Share image"])
    }
    func testFolderActionsAreAtomicAndRejectCycles() throws {
        let root = NotebookFolder(name: "Documents")
        var library = NoteLibrarySnapshot(folders: [root])
        let a = try XCTUnwrap(LibraryAction(kind: .createFolder, name: "Course").apply(to: &library))
        let b = try XCTUnwrap(LibraryAction(kind: .createFolder, parentID: a, name: "Analysis").apply(to: &library))
        let note = try library.addNote(title: "Course 1", folderID: root.id)
        try LibraryAction(kind: .moveDocuments, folderID: b, documentIDs: [note.id]).apply(to: &library)
        XCTAssertEqual(library.note(id: note.id)?.folderID, b)
        XCTAssertEqual(library.folderPath(to: b).map(\.name), ["Documents", "Course", "Analysis"])
        let before = library
        XCTAssertThrowsError(try LibraryAction(kind: .moveDocuments, folderID: a, documentIDs: [note.id, UUID()]).apply(to: &library))
        XCTAssertEqual(library, before)
        XCTAssertThrowsError(try LibraryAction(kind: .moveFolder, folderID: a, parentID: b).apply(to: &library))
        XCTAssertEqual(library, before)
        XCTAssertThrowsError(try LibraryAction(kind: .moveFolder, folderID: root.id, parentID: b).apply(to: &library))
        try LibraryAction(kind: .renameFolder, folderID: a, name: "University").apply(to: &library)
        XCTAssertEqual(library.folder(id: a)?.name, "University")
        let roundtrip = try JSONDecoder().decode(NoteLibrarySnapshot.self, from: JSONEncoder().encode(library))
        XCTAssertEqual(roundtrip, library)
    }
    func testCreateAndImportUseChosenFolderAndPersist() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root); await store.load()
        let folder = try XCTUnwrap(store.apply(LibraryAction(kind: .createFolder, name: "PDF")))
        let created = await store.create(title: "Note", folderID: folder)
        let note = try XCTUnwrap(created)
        XCTAssertEqual(store.library.note(id: note)?.folderID, folder)
        let file = root.appendingPathComponent("input.pdf")
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 300)).pdfData { context in context.beginPage() }
        try data.write(to: file)
        let imported = await store.importFile(file, folderID: folder)
        let pdf = try XCTUnwrap(imported)
        XCTAssertEqual(store.library.note(id: pdf)?.folderID, folder)
        let saved = await store.flush(); XCTAssertTrue(saved)
        let loaded = try await store.disk.load()
        XCTAssertEqual(Set(loaded.folder(id: folder)?.noteIDs ?? []), Set([note, pdf]))
    }
}
