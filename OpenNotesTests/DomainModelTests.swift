// Derived from Signotes, copyright (c) 2026 Diego Signorastri. MIT; see docs/Signotes-LICENSE.
import XCTest
@testable import OpenNotes

final class DomainModelTests: XCTestCase {
    func testA4PortraitAspectRatio() {
        XCTAssertEqual(
            PageFormat.a4Portrait.aspectRatio,
            210.0 / 297.0,
            accuracy: 0.000_001
        )
    }

    func testSeedLibraryContainsInitialMathNote() {
        let seed = NoteLibrarySnapshot.seed

        XCTAssertEqual(seed.schemaVersion, 1)
        XCTAssertEqual(seed.folders.count, 1)
        XCTAssertEqual(seed.folders.first?.name, "Math")
        XCTAssertEqual(seed.notes.count, 1)
        XCTAssertEqual(seed.notes.first?.title, "Lesson 1")
        XCTAssertEqual(seed.pages.count, 1)
        XCTAssertEqual(seed.pages.first?.template, .grid)
    }

    func testSeedLibraryJSONRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(NoteLibrarySnapshot.seed)
        let decoded = try decoder.decode(NoteLibrarySnapshot.self, from: data)

        XCTAssertEqual(decoded, NoteLibrarySnapshot.seed)
    }

    func testDefaultToolPresetsHaveStableIDsAndAllKinds() {
        XCTAssertEqual(DrawingToolPreset.defaults.first?.id, DrawingToolPreset.defaultFountainPenID)
        XCTAssertEqual(DrawingToolPreset.defaultFountainPen.kind, .fountainPen)
        XCTAssertEqual(DrawingToolPreset.defaultFountainPen.colorHex, "#000000")
        XCTAssertEqual(DrawingToolPreset.defaultFountainPen.width, 2.4)

        XCTAssertEqual(
            DrawingToolPreset.defaults.map(\.kind),
            [.fountainPen, .pen, .pencil, .marker, .eraser, .lasso]
        )
    }

    func testDrawingToolPresetClampsWidth() {
        let tooSmall = DrawingToolPreset(name: "Too Small", kind: .pen, width: -2.0)
        let tooLarge = DrawingToolPreset(name: "Too Large", kind: .marker, width: 99.0)

        XCTAssertEqual(tooSmall.width, DrawingToolPreset.minimumWidth)
        XCTAssertEqual(tooLarge.width, DrawingToolPreset.maximumWidth)
    }

    func testAddUpdateAndDeleteCustomToolPreset() throws {
        var library = NoteLibrarySnapshot()
        let preset = library.addToolPreset(
            name: "Red pen",
            kind: .pen,
            colorHex: "#FF0000",
            width: 3.5
        )

        try library.updateToolPreset(
            id: preset.id,
            name: "Stilo verde",
            kind: .fountainPen,
            colorHex: "#00FF00",
            width: 4.0
        )

        XCTAssertEqual(library.toolPreset(id: preset.id)?.name, "Stilo verde")
        XCTAssertEqual(library.toolPreset(id: preset.id)?.kind, .fountainPen)
        XCTAssertEqual(library.toolPreset(id: preset.id)?.colorHex, "#00FF00")
        XCTAssertEqual(library.toolPreset(id: preset.id)?.width, 4.0)

        try library.deleteCustomToolPreset(id: preset.id)

        XCTAssertNil(library.toolPreset(id: preset.id))
    }

    func testCannotDeleteBuiltInToolPreset() {
        var library = NoteLibrarySnapshot()

        XCTAssertThrowsError(try library.deleteCustomToolPreset(id: DrawingToolPreset.defaultFountainPenID)) { error in
            XCTAssertEqual(error as? LibraryMutationError, .cannotDeleteBuiltInToolPreset(DrawingToolPreset.defaultFountainPenID))
        }
    }

    func testLibrarySupportsRecursiveFolders() throws {
        var library = NoteLibrarySnapshot()

        let root = try library.addFolder(name: "Math", colorHex: "#F2C94C")
        let child = try library.addFolder(name: "Analisi", colorHex: "#4F8BFF", parentID: root.id)
        let note = try library.addNote(
            title: "Lesson 1",
            colorHex: "#5AC8A8",
            folderID: child.id,
            now: Date(timeIntervalSince1970: 10)
        )

        XCTAssertEqual(library.rootFolders.map(\.id), [root.id])
        XCTAssertEqual(library.childFolders(of: root.id).map(\.id), [child.id])
        XCTAssertEqual(library.notes(in: child.id).map(\.id), [note.id])
        XCTAssertEqual(library.folder(id: root.id)?.colorHex, "#F2C94C")
        XCTAssertEqual(library.folder(id: child.id)?.colorHex, "#4F8BFF")
        XCTAssertEqual(library.note(id: note.id)?.colorHex, "#5AC8A8")
        XCTAssertEqual(library.firstPage(in: note.id)?.noteID, note.id)
        XCTAssertFalse(library.containsFolderCycle())
    }

    func testLibraryDetectsFolderCycles() throws {
        let rootID = UUID()
        let childID = UUID()

        let root = NotebookFolder(id: rootID, name: "Root", childFolderIDs: [childID])
        let child = NotebookFolder(id: childID, name: "Child", childFolderIDs: [rootID])
        let library = NoteLibrarySnapshot(folders: [root, child])

        XCTAssertTrue(library.containsFolderCycle())
    }

    func testUpdateFolderNameAndColor() throws {
        var library = NoteLibrarySnapshot()
        let folder = try library.addFolder(name: "Math", colorHex: "#F2C94C")

        try library.updateFolder(id: folder.id, name: "Analisi", colorHex: "#4F8BFF")

        XCTAssertEqual(library.folder(id: folder.id)?.name, "Analisi")
        XCTAssertEqual(library.folder(id: folder.id)?.colorHex, "#4F8BFF")
    }

    func testUpdateNoteTitleColorAndTimestamp() throws {
        var library = NoteLibrarySnapshot()
        let folder = try library.addFolder(name: "Math")
        let note = try library.addNote(
            title: "Lesson 1",
            colorHex: "#F2C94C",
            folderID: folder.id,
            now: Date(timeIntervalSince1970: 10)
        )

        try library.updateNote(
            id: note.id,
            title: "Derivate",
            colorHex: "#5AC8A8",
            now: Date(timeIntervalSince1970: 20)
        )

        XCTAssertEqual(library.note(id: note.id)?.title, "Derivate")
        XCTAssertEqual(library.note(id: note.id)?.colorHex, "#5AC8A8")
        XCTAssertEqual(library.note(id: note.id)?.updatedAt, Date(timeIntervalSince1970: 20))
    }

    func testUpdatePageTemplateMutatesOnlyPageMetadata() throws {
        var library = NoteLibrarySnapshot()
        let folder = try library.addFolder(name: "Math")
        let note = try library.addNote(title: "Lesson 1", folderID: folder.id)
        let page = try XCTUnwrap(library.firstPage(in: note.id))

        try library.updatePageTemplate(pageID: page.id, template: .ruled)

        let updatedPage = try XCTUnwrap(library.firstPage(in: note.id))
        XCTAssertEqual(updatedPage.template, .ruled)
        XCTAssertEqual(updatedPage.drawingResourceID, page.drawingResourceID)
        XCTAssertEqual(updatedPage.format, page.format)
    }

    func testAppendPageAddsOrderedPageAndInheritsRequestedTemplate() throws {
        var library = NoteLibrarySnapshot()
        let folder = try library.addFolder(name: "Math")
        let note = try library.addNote(title: "Lesson 1", folderID: folder.id)
        let firstPage = try XCTUnwrap(library.firstPage(in: note.id))

        let secondPage = try library.appendPage(toNoteID: note.id, template: .ruled)

        let orderedPages = library.pages(in: note.id)
        XCTAssertEqual(orderedPages.map(\.id), [firstPage.id, secondPage.id])
        XCTAssertEqual(secondPage.index, 1)
        XCTAssertEqual(secondPage.template, .ruled)
        XCTAssertEqual(secondPage.format, .a4Portrait)
        XCTAssertNotEqual(secondPage.drawingResourceID, firstPage.drawingResourceID)
        XCTAssertEqual(library.note(id: note.id)?.pageIDs, [firstPage.id, secondPage.id])
    }

    func testInsertPageBeforeAndAfterReindexesPages() throws {
        var library = NoteLibrarySnapshot()
        let folder = try library.addFolder(name: "Math")
        let note = try library.addNote(title: "Lesson 1", folderID: folder.id)
        let firstPage = try XCTUnwrap(library.firstPage(in: note.id))
        let lastPage = try library.appendPage(toNoteID: note.id, template: .ruled)

        let insertedBefore = try library.insertPage(before: lastPage.id, template: .dotted)
        let insertedAfter = try library.insertPage(after: firstPage.id, template: .blank)

        let orderedPages = library.pages(in: note.id)
        XCTAssertEqual(orderedPages.map(\.id), [firstPage.id, insertedAfter.id, insertedBefore.id, lastPage.id])
        XCTAssertEqual(orderedPages.map(\.index), [0, 1, 2, 3])
        XCTAssertEqual(insertedBefore.template, .dotted)
        XCTAssertEqual(insertedAfter.template, .blank)
        XCTAssertEqual(library.note(id: note.id)?.pageIDs, orderedPages.map(\.id))
    }

    func testDuplicatePageCreatesNewMetadataAfterSource() throws {
        var library = NoteLibrarySnapshot()
        let folder = try library.addFolder(name: "Math")
        let note = try library.addNote(title: "Lesson 1", folderID: folder.id)
        let firstPage = try XCTUnwrap(library.firstPage(in: note.id))
        try library.updatePageTemplate(pageID: firstPage.id, template: .dotted)

        let duplicate = try library.duplicatePage(after: firstPage.id)

        let orderedPages = library.pages(in: note.id)
        XCTAssertEqual(orderedPages.map(\.id), [firstPage.id, duplicate.id])
        XCTAssertEqual(duplicate.index, 1)
        XCTAssertEqual(duplicate.format, firstPage.format)
        XCTAssertEqual(duplicate.template, .dotted)
        XCTAssertNotEqual(duplicate.drawingResourceID, firstPage.drawingResourceID)
    }

    func testDeletePageRemovesMetadataAndSelectsNearestRemainingPage() throws {
        var library = NoteLibrarySnapshot()
        let folder = try library.addFolder(name: "Math")
        let note = try library.addNote(title: "Lesson 1", folderID: folder.id)
        let firstPage = try XCTUnwrap(library.firstPage(in: note.id))
        let secondPage = try library.appendPage(toNoteID: note.id, template: .ruled)
        let thirdPage = try library.appendPage(toNoteID: note.id, template: .dotted)

        let deletion = try library.deletePage(id: secondPage.id)

        let orderedPages = library.pages(in: note.id)
        XCTAssertEqual(orderedPages.map(\.id), [firstPage.id, thirdPage.id])
        XCTAssertEqual(orderedPages.map(\.index), [0, 1])
        XCTAssertEqual(deletion.drawingResourceID, secondPage.drawingResourceID)
        XCTAssertEqual(deletion.preferredSelectionPageID, thirdPage.id)
        XCTAssertNil(library.page(id: secondPage.id))
        XCTAssertEqual(library.note(id: note.id)?.pageIDs, [firstPage.id, thirdPage.id])
    }

    func testDeleteOnlyPageThrows() throws {
        var library = NoteLibrarySnapshot()
        let folder = try library.addFolder(name: "Math")
        let note = try library.addNote(title: "Lesson 1", folderID: folder.id)
        let page = try XCTUnwrap(library.firstPage(in: note.id))

        XCTAssertThrowsError(try library.deletePage(id: page.id)) { error in
            XCTAssertEqual(error as? LibraryMutationError, .cannotDeleteLastPage(note.id))
        }
    }

    func testMovePageReordersIndexesWithoutChangingDrawingResources() throws {
        var library = NoteLibrarySnapshot()
        let folder = try library.addFolder(name: "Math")
        let note = try library.addNote(title: "Lesson 1", folderID: folder.id)
        let firstPage = try XCTUnwrap(library.firstPage(in: note.id))
        let secondPage = try library.appendPage(toNoteID: note.id, template: .ruled)
        let thirdPage = try library.appendPage(toNoteID: note.id, template: .dotted)

        try library.movePage(id: thirdPage.id, toIndex: 0)

        let orderedPages = library.pages(in: note.id)
        XCTAssertEqual(orderedPages.map(\.id), [thirdPage.id, firstPage.id, secondPage.id])
        XCTAssertEqual(orderedPages.map(\.index), [0, 1, 2])
        XCTAssertEqual(library.page(id: thirdPage.id)?.drawingResourceID, thirdPage.drawingResourceID)
    }

    func testDeleteNoteRemovesPagesAndParentReference() throws {
        var library = NoteLibrarySnapshot()
        let folder = try library.addFolder(name: "Math")
        let note = try library.addNote(title: "Lesson 1", folderID: folder.id)
        let page = try XCTUnwrap(library.firstPage(in: note.id))
        let secondPage = try library.appendPage(toNoteID: note.id, template: .dotted)

        let deletedResourceIDs = try library.deleteNote(id: note.id)

        XCTAssertNil(library.note(id: note.id))
        XCTAssertNil(library.firstPage(in: note.id))
        XCTAssertFalse(library.folder(id: folder.id)?.noteIDs.contains(note.id) ?? true)
        XCTAssertEqual(Set(deletedResourceIDs), Set([page.drawingResourceID, secondPage.drawingResourceID]))
    }

    func testDeleteFolderTreeRemovesDescendantsNotesPagesAndParentReference() throws {
        var library = NoteLibrarySnapshot()
        let root = try library.addFolder(name: "Math")
        let child = try library.addFolder(name: "Analisi", parentID: root.id)
        let grandchild = try library.addFolder(name: "Serie", parentID: child.id)
        let note = try library.addNote(title: "Lesson 1", folderID: grandchild.id)
        let page = try XCTUnwrap(library.firstPage(in: note.id))
        let secondPage = try library.appendPage(toNoteID: note.id, template: .ruled)

        let deletedResourceIDs = try library.deleteFolderTree(id: child.id)

        XCTAssertNotNil(library.folder(id: root.id))
        XCTAssertNil(library.folder(id: child.id))
        XCTAssertNil(library.folder(id: grandchild.id))
        XCTAssertNil(library.note(id: note.id))
        XCTAssertNil(library.firstPage(in: note.id))
        XCTAssertFalse(library.folder(id: root.id)?.childFolderIDs.contains(child.id) ?? true)
        XCTAssertEqual(Set(deletedResourceIDs), Set([page.drawingResourceID, secondPage.drawingResourceID]))
    }

    func testMoveNoteChangesParentFolderReference() throws {
        var library = NoteLibrarySnapshot()
        let source = try library.addFolder(name: "Math")
        let destination = try library.addFolder(name: "Fisica")
        let note = try library.addNote(title: "Lesson 1", folderID: source.id)

        try library.moveNote(id: note.id, toFolderID: destination.id)

        XCTAssertFalse(library.folder(id: source.id)?.noteIDs.contains(note.id) ?? true)
        XCTAssertTrue(library.folder(id: destination.id)?.noteIDs.contains(note.id) ?? false)
        XCTAssertEqual(library.note(id: note.id)?.folderID, destination.id)
    }

    func testMoveFolderChangesParentFolderReference() throws {
        var library = NoteLibrarySnapshot()
        let sourceParent = try library.addFolder(name: "Math")
        let destinationParent = try library.addFolder(name: "Fisica")
        let child = try library.addFolder(name: "Analisi", parentID: sourceParent.id)

        try library.moveFolder(id: child.id, toFolderID: destinationParent.id)

        XCTAssertFalse(library.folder(id: sourceParent.id)?.childFolderIDs.contains(child.id) ?? true)
        XCTAssertTrue(library.folder(id: destinationParent.id)?.childFolderIDs.contains(child.id) ?? false)
        XCTAssertEqual(library.parentFolder(of: child.id)?.id, destinationParent.id)
    }

    func testMoveFolderToRootRemovesParentReference() throws {
        var library = NoteLibrarySnapshot()
        let root = try library.addFolder(name: "Math")
        let child = try library.addFolder(name: "Analisi", parentID: root.id)

        try library.moveFolderToRoot(id: child.id)

        XCTAssertNil(library.parentFolder(of: child.id))
        XCTAssertEqual(Set(library.rootFolders.map(\.id)), Set([root.id, child.id]))
    }

    func testMoveFolderIntoItselfThrows() throws {
        var library = NoteLibrarySnapshot()
        let folder = try library.addFolder(name: "Math")

        XCTAssertThrowsError(try library.moveFolder(id: folder.id, toFolderID: folder.id)) { error in
            XCTAssertEqual(error as? LibraryMutationError, .invalidFolderMove(folder.id, folder.id))
        }
    }

    func testMoveFolderIntoDescendantThrows() throws {
        var library = NoteLibrarySnapshot()
        let root = try library.addFolder(name: "Math")
        let child = try library.addFolder(name: "Analisi", parentID: root.id)
        let grandchild = try library.addFolder(name: "Serie", parentID: child.id)

        XCTAssertThrowsError(try library.moveFolder(id: root.id, toFolderID: grandchild.id)) { error in
            XCTAssertEqual(error as? LibraryMutationError, .invalidFolderMove(root.id, grandchild.id))
        }
    }

    func testLegacyHomeFolderMergesIntoTheSharedHome() {
        var legacy = NotebookFolder(name: "Home")
        var work = NotebookFolder(name: "Work")
        let homeNote = NoteDocument(folderID: legacy.id, title: "At home")
        let workNote = NoteDocument(folderID: work.id, title: "At work")
        legacy.noteIDs = [homeNote.id]; legacy.childFolderIDs = [work.id]; work.noteIDs = [workNote.id]
        // The other device's home arrived through sync as an ordinary root folder.
        var shared = NotebookFolder(id: NotebookFolder.homeID, name: "My notebooks")
        let synced = NoteDocument(folderID: shared.id, title: "From the phone")
        shared.noteIDs = [synced.id]
        var library = NoteLibrarySnapshot(); library.folders = [legacy, work, shared]; library.notes = [homeNote, workNote, synced]
        XCTAssertTrue(library.adoptSharedHomeFolder(now: Date(timeIntervalSince1970: 1)))
        XCTAssertEqual(library.folders.first?.id, NotebookFolder.homeID)
        XCTAssertEqual(Set(library.notes(in: NotebookFolder.homeID).map(\.id)), [homeNote.id, synced.id])
        XCTAssertEqual(library.childFolders(of: NotebookFolder.homeID).map(\.id), [work.id])
        XCTAssertEqual(library.notes.first { $0.id == homeNote.id }?.folderID, NotebookFolder.homeID)
        XCTAssertNotNil(library.folder(id: legacy.id)?.deletedAt, "The emptied legacy home is trashed so other devices drop it")
        XCTAssertFalse(library.rootFolders.contains { $0.id == legacy.id })
        XCTAssertFalse(library.containsFolderCycle())
        XCTAssertFalse(library.adoptSharedHomeFolder(), "Idempotent")
        var fresh = NoteLibrarySnapshot(); fresh.folders = [NotebookFolder(id: NotebookFolder.homeID, name: "My notebooks")]
        XCTAssertFalse(fresh.adoptSharedHomeFolder())
    }
}
