import XCTest
import UIKit
import PDFKit
@testable import OpenNotes

@MainActor
final class StorageAndPDFTests: XCTestCase {
    func makeStore() async -> LibraryStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LibraryStore(root: root); await store.load(); return store
    }
    func testNotebookPersistsTrashRecoveryAndDuplicate() async throws {
        let store = await makeStore()
        let created = await store.create()
        let id = try XCTUnwrap(created)
        let first = try XCTUnwrap(store.library.firstPage(in: id))
        let duplicate = await store.addPage(noteID: id, after: first.id, duplicate: true)
        XCTAssertNotNil(duplicate)
        store.update(id) { $0.title = "Course"; $0.deletedAt = Date() }
        await store.flush()
        let saved = try await store.disk.load()
        XCTAssertEqual(saved.note(id: id)?.title, "Course")
        XCTAssertNotNil(saved.note(id: id)?.deletedAt)
        XCTAssertEqual(saved.pages(in: id).count, 2)
        store.update(id) { $0.deletedAt = nil }; await store.flush()
        let recovered = try await store.disk.load()
        XCTAssertNil(recovered.note(id: id)?.deletedAt)
    }
    func testPDFSourcePreservedAndAnnotatedExport() async throws {
        let store = await makeStore()
        let input = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        let bounds = CGRect(x: 0, y: 0, width: 500, height: 700)
        try UIGraphicsPDFRenderer(bounds: bounds).writePDF(to: input) { ctx in
            ctx.beginPage(); ("Searchable original" as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
            ctx.beginPage()
        }
        let original = try Data(contentsOf: input)
        let imported = await store.importFile(input)
        let id = try XCTUnwrap(imported)
        let page = try XCTUnwrap(store.library.firstPage(in: id))
        XCTAssertEqual(page.pdfText?.source, .pdf)
        XCTAssertTrue(page.pdfText?.text.contains("Searchable original") == true)
        XCTAssertNil(page.recognizedText)
        XCTAssertTrue(store.matchingNotes("Searchable original").contains { $0.id == id })
        let previousDate = store.library.note(id: id)?.updatedAt
        let position = try XCTUnwrap(store.library.pages.firstIndex { $0.id == page.id })
        store.library.pages[position].pdfText = nil
        await store.indexPDFText(in: id)
        XCTAssertEqual(store.library.note(id: id)?.updatedAt, previousDate, "Indexing a PDF must not move the notebook in recents")
        XCTAssertTrue(store.library.page(id: page.id)?.pdfText?.text.contains("Searchable original") == true)
        let source = try await store.disk.read(try XCTUnwrap(page.backgroundID))
        XCTAssertEqual(source, original)
        let points = [CGPoint(x: 50, y: 100), CGPoint(x: 400, y: 300)].enumerated().map { i, p in
            InkStrokePoint(location: p, timeOffset: Double(i), size: CGSize(width: 8, height: 8), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let stroke = InkStroke(ink: InkInk(.pen, color: .red), path: InkStrokePath(controlPoints: points, creationDate: Date()))
        let drawing = InkDrawing(strokes: [stroke])
        try await store.disk.write(drawing.dataRepresentation(), name: page.drawingResourceID)
        let archive = try await store.archive(id)
        let output = input.deletingPathExtension().appendingPathExtension("export.pdf")
        try PageRenderer.export(archive, indices: 0...0, output: output)
        let pdf = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(pdf.pageCount, 1)
        XCTAssertTrue(pdf.string?.contains("Searchable original") == true)
        let exported = try XCTUnwrap(pdf.page(at: 0)?.thumbnail(of: CGSize(width: 500, height: 700), for: .mediaBox).pngData())
        let blank = PageRenderer.image(page, data: original).pngData()
        XCTAssertNotEqual(exported, blank)
        let persisted = try await store.disk.read(page.drawingResourceID)
        XCTAssertEqual(try InkDrawing(data: XCTUnwrap(persisted)).strokes.count, 1)
        let roundtrip = try JSONDecoder().decode(NotebookArchive.self, from: CloudSync.encode(archive))
        let copy = try await store.importArchive(roundtrip)
        XCTAssertNotEqual(id, copy)
        XCTAssertEqual(store.library.pages(in: copy).count, 2)
    }
    func testPDFExportRejectsUnsupportedInkInsteadOfWritingBlankPage() async throws {
        let store = await makeStore()
        let created = await store.create()
        let id = try XCTUnwrap(created)
        var archive = try await store.archive(id)
        archive.resources[archive.pages[0].drawingResourceID] = Data("legacy or corrupt ink".utf8)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        XCTAssertThrowsError(try PageRenderer.export(archive, indices: 0...0, output: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
    func testCorruptLibraryIsNotSilentlyReset() async throws {
        let store = await makeStore()
        _ = await store.create(); await store.flush()
        let root = await store.disk.root
        let url = root.appendingPathComponent("library.json")
        let corrupt = Data("broken".utf8)
        try corrupt.write(to: url)
        do { _ = try await store.disk.load(); XCTFail("Corrupt data accepted") } catch { }
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        do { try await store.disk.write(Data(), name: "../escape"); XCTFail("Path traversal accepted") } catch { }
    }
    func testAutosaveFlushAndReadOnlyPolicy() async throws {
        let store = await makeStore()
        let created = await store.create()
        let id = try XCTUnwrap(created)
        let editor = EditorSession(store: store, noteID: id)
        await editor.open()
        editor.changed(InkDrawing())
        XCTAssertTrue(editor.dirty)
        let flushed = await editor.flush()
        XCTAssertTrue(flushed)
        XCTAssertFalse(editor.dirty)
        let archive = try await store.archive(id)
        XCTAssertNoThrow(try archive.validate())
        var malicious = archive; malicious.resources["../secret"] = Data()
        XCTAssertThrowsError(try malicious.validate())
    }
    func testPendingJournalRecoversInterruptedMetadataCommit() async throws {
        let store = await makeStore()
        let created = await store.create()
        let id = try XCTUnwrap(created)
        let flushed = await store.flush()
        XCTAssertTrue(flushed)
        var pending = store.library
        pending.notes[0].title = "Recovered journal"
        let root = await store.disk.root
        let journal = root.appendingPathComponent("library.pending.json")
        try JSONEncoder().encode(pending).write(to: journal, options: .atomic)
        try Data("interrupted metadata".utf8).write(to: root.appendingPathComponent("library.json"))
        let recovered = try await store.disk.load()
        XCTAssertEqual(recovered.note(id: id)?.title, "Recovered journal")
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        let reopened = try await store.disk.load()
        XCTAssertEqual(reopened, recovered)
    }

    func testIncompleteJournalDoesNotOverwriteCommittedMetadata() async throws {
        let store = await makeStore()
        _ = await store.create()
        let flushed = await store.flush()
        XCTAssertTrue(flushed)
        let root = await store.disk.root
        let committedURL = root.appendingPathComponent("library.json")
        let committed = try Data(contentsOf: committedURL)
        var pending = store.library
        pending.pages[0].drawingResourceID = "missing.drawing"
        let journal = root.appendingPathComponent("library.pending.json")
        try JSONEncoder().encode(pending).write(to: journal, options: .atomic)
        do { _ = try await store.disk.load(); XCTFail("Incomplete commit accepted") } catch { }
        XCTAssertEqual(try Data(contentsOf: committedURL), committed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
    }

    func testExplicitBackupRestoreDiscardsPendingJournal() async throws {
        let store = await makeStore()
        let created = await store.create()
        let id = try XCTUnwrap(created)
        let flushed = await store.flush()
        XCTAssertTrue(flushed)
        let root = await store.disk.root
        let backup = store.library
        try JSONEncoder().encode(backup).write(to: root.appendingPathComponent("library.backup.json"))
        var pending = backup
        pending.notes[0].title = "Abandoned pending revision"
        try JSONEncoder().encode(pending).write(to: root.appendingPathComponent("library.pending.json"))
        _ = try await store.disk.restoreBackup()
        let reopened = try await store.disk.load()
        XCTAssertEqual(reopened.note(id: id)?.title, backup.note(id: id)?.title)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("library.pending.json").path))
    }

    func testCloudReplacementPreservesCanonicalIDsAndRejectsStaleLocalVersion() async throws {
        let store = await makeStore()
        let created = await store.create()
        let id = try XCTUnwrap(created)
        let editor = EditorSession(store: store, noteID: id)
        await editor.open()
        var remote = try await store.archive(id)
        let expected = try XCTUnwrap(store.library.note(id: id))
        let originalResource = remote.pages[0].drawingResourceID
        remote.note.title = "Edited remotely"
        remote.note.updatedAt = expected.updatedAt.addingTimeInterval(1)
        let stroke = redStroke()
        remote.resources[originalResource] = InkDrawing(strokes: [stroke]).dataRepresentation()
        let applied = try await store.applyCloudArchive(remote, expected: expected)
        XCTAssertEqual(applied, id)
        XCTAssertEqual(store.library.notes.count, 1)
        XCTAssertEqual(store.library.note(id: id)?.pageIDs, remote.note.pageIDs)
        XCTAssertEqual(store.library.page(id: remote.pages[0].id)?.noteID, id)
        XCTAssertNotEqual(store.library.page(id: remote.pages[0].id)?.drawingResourceID, originalResource)
        XCTAssertEqual(editor.drawing.strokes.map(\.id), [stroke.id])
        XCTAssertEqual(editor.page?.id, remote.pages[0].id)
        let reopened = try await store.disk.load()
        XCTAssertEqual(reopened.note(id: id)?.title, "Edited remotely")
        do { _ = try await store.applyCloudArchive(remote, expected: expected); XCTFail("Stale cloud update accepted") } catch { }
        XCTAssertEqual(store.library, reopened)
        editor.changed(InkDrawing())
        let latest = store.library.note(id: id)
        do { _ = try await store.applyCloudArchive(remote, expected: latest); XCTFail("Pending handwriting overwritten") } catch { }
        XCTAssertTrue(editor.dirty)
        XCTAssertTrue(editor.drawing.strokes.isEmpty)
    }
    private func redStroke() -> InkStroke {
        let points = [CGPoint(x: 80, y: 120), CGPoint(x: 420, y: 120)].enumerated().map { index, point in
            InkStrokePoint(location: point, timeOffset: Double(index), size: CGSize(width: 16, height: 16), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return InkStroke(ink: InkInk(.pen, color: .red), path: InkStrokePath(controlPoints: points, creationDate: Date()))
    }

    func testFailedMetadataSavePreservesCommittedInkAndRetriesPendingRevision() async throws {
        let store = await makeStore()
        let created = await store.create()
        let id = try XCTUnwrap(created)
        let editor = EditorSession(store: store, noteID: id); await editor.open()
        editor.changed(InkDrawing())
        let initialSaved = await editor.flush(); XCTAssertTrue(initialSaved)
        let originalPage = try XCTUnwrap(editor.page)
        let committedInk = try await store.disk.read(originalPage.drawingResourceID)
        let originalInk = try XCTUnwrap(committedInk)
        let root = await store.disk.root
        let library = root.appendingPathComponent("library.json")
        let originalLibrary = try Data(contentsOf: library)
        defer {
            try? FileManager.default.removeItem(at: library)
            try? originalLibrary.write(to: library, options: .atomic)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.removeItem(at: library)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: false)
        let stroke = redStroke()
        editor.changed(InkDrawing(strokes: [stroke]))
        let failed = await editor.flush()
        XCTAssertFalse(failed)
        XCTAssertTrue(editor.dirty, "A failed metadata save must retain the pending ink")
        let preserved = try await store.disk.read(originalPage.drawingResourceID)
        XCTAssertEqual(preserved, originalInk, "A failed revision must not overwrite the committed drawing")
        try FileManager.default.removeItem(at: library)
        try originalLibrary.write(to: library, options: .atomic)
        let retried = await editor.flush()
        XCTAssertTrue(retried); XCTAssertFalse(editor.dirty)
        let reopenedStore = LibraryStore(root: root); await reopenedStore.load()
        let archive = try await reopenedStore.archive(id)
        let resource = try XCTUnwrap(archive.resources[try XCTUnwrap(archive.pages.first).drawingResourceID])
        let restored = try InkDrawing(data: resource)
        XCTAssertEqual(restored.strokes.map(\.id), [stroke.id])
    }

    func testExportIncludesLatestPendingInk() async throws {
        let store = await makeStore()
        let created = await store.create()
        let id = try XCTUnwrap(created)
        let editor = EditorSession(store: store, noteID: id); await editor.open()
        let stroke = redStroke()
        editor.changed(InkDrawing(strokes: [stroke]))
        XCTAssertTrue(editor.dirty)
        editor.cloudDocumentEditorPresented = true
        let archive = try await store.archive(id)
        XCTAssertFalse(editor.dirty)
        let page = try XCTUnwrap(archive.pages.first)
        let drawing = try InkDrawing(data: XCTUnwrap(archive.resources[page.drawingResourceID]))
        XCTAssertEqual(drawing.strokes.map(\.id), [stroke.id])
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        try PageRenderer.export(archive, indices: 0...0, output: output)
        let pdfPage = try XCTUnwrap(PDFDocument(url: output)?.page(at: 0))
        let image = try XCTUnwrap(pdfPage.thumbnail(of: CGSize(width: 397, height: 562), for: .mediaBox).cgImage)
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let hasRedInk = stride(from: 0, to: pixels.count, by: 4).contains { pixels[$0] > 180 && pixels[$0 + 1] < 80 && pixels[$0 + 2] < 80 }
        XCTAssertTrue(hasRedInk, "The exported PDF must visibly contain the pending red stroke")
    }

    func testImageElementsSearchAndCustomPaperPersistence() async throws {
        let store = await makeStore()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 200)).image { context in
            UIColor.green.setFill(); context.fill(CGRect(x: 0, y: 0, width: 320, height: 200))
        }
        let data = try XCTUnwrap(image.pngData())
        let input = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try data.write(to: input)
        let imported = await store.importFile(input)
        let id = try XCTUnwrap(imported)
        var page = try XCTUnwrap(store.library.firstPage(in: id))
        page.elements = [PageElement(kind: .text, text: "Botanique"), PageElement(kind: .image, resource: page.backgroundID)]
        page.recognizedText = "Extracted PDF text"
        store.updatePage(page)
        store.update(id) { $0.favorite = true; $0.title = "Course" }
        store.library.customPapers.append(CustomPaper(name: "My paper", template: .blank, resource: page.backgroundID, pdfIndex: nil, width: 320, height: 200))
        store.persist(); await store.flush()
        XCTAssertEqual(store.matchingNotes("botanique").map(\.id), [id])
        XCTAssertEqual(store.matchingNotes("Extracted PDF").map(\.id), [id])
        XCTAssertEqual(store.matchingNotes("course", favorites: true).map(\.id), [id])
        let archive = try await store.archive(id)
        XCTAssertEqual(archive.resources[try XCTUnwrap(page.backgroundID)], data)
        let restored = try await store.disk.load()
        XCTAssertEqual(restored.customPapers.count, 1)
        let copy = try await store.importArchive(archive)
        let copied = try XCTUnwrap(store.library.firstPage(in: copy))
        XCTAssertEqual(copied.elements?.count, 2)
        XCTAssertNotEqual(copied.backgroundID, page.backgroundID)
        let copiedArchive = try await store.archive(copy)
        XCTAssertNoThrow(try copiedArchive.validate())
    }
    func testChecksumsDeterministicAndConflictCopiesPreserveOriginal() async throws {
        let store = await makeStore()
        let created = await store.create(title: "Local")
        let id = try XCTUnwrap(created)
        let archive = try await store.archive(id)
        XCTAssertEqual(try CloudSync.encode(archive), try CloudSync.encode(archive))
        var remote = archive; remote.note.title = "Remote conflict"
        let copy = try await store.importArchive(remote)
        XCTAssertEqual(store.library.note(id: id)?.title, "Local")
        XCTAssertEqual(store.library.note(id: copy)?.title, "Remote conflict")
        store.cloud.resolve(SyncConflict(localID: id, remoteCopyID: copy), keep: 1)
        XCTAssertNil(store.library.note(id: id)?.deletedAt)
        XCTAssertNotNil(store.library.note(id: copy)?.deletedAt)
        XCTAssertNotEqual(CloudSync.checksum(try CloudSync.encode(archive)), CloudSync.checksum(try CloudSync.encode(remote)))
    }
}
