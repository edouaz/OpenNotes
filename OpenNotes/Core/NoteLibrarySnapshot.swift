// Derived from Signotes, copyright (c) 2026 Diego Signorastri. MIT; see docs/Signotes-LICENSE.
import Foundation

struct NoteLibrarySnapshot: Codable, Equatable, Sendable {
    var sharedImports: [String: UUID] = [:]
    var customPapers: [CustomPaper] = []
    var schemaVersion: Int
    var folders: [NotebookFolder]
    var notes: [NoteDocument]
    var pages: [NotePage]
    var toolPresets: [DrawingToolPreset]

    init(
        schemaVersion: Int = 1,
        folders: [NotebookFolder] = [],
        notes: [NoteDocument] = [],
        pages: [NotePage] = [],
        toolPresets: [DrawingToolPreset] = DrawingToolPreset.defaults
    ) {
        self.schemaVersion = schemaVersion
        self.folders = folders
        self.notes = notes
        self.pages = pages
        self.toolPresets = toolPresets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        sharedImports = try container.decodeIfPresent([String: UUID].self, forKey: .sharedImports) ?? [:]
        customPapers = try container.decodeIfPresent([CustomPaper].self, forKey: .customPapers) ?? []
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        folders = try container.decode([NotebookFolder].self, forKey: .folders)
        notes = try container.decode([NoteDocument].self, forKey: .notes)
        pages = try container.decode([NotePage].self, forKey: .pages)
        toolPresets = try container.decodeIfPresent([DrawingToolPreset].self, forKey: .toolPresets) ?? DrawingToolPreset.defaults
    }

    private enum CodingKeys: String, CodingKey {
        case sharedImports
        case customPapers
        case schemaVersion
        case folders
        case notes
        case pages
        case toolPresets
    }
}

extension NoteLibrarySnapshot {
    var rootFolders: [NotebookFolder] {
        let childIDs = Set(folders.flatMap(\.childFolderIDs))
        return folders
            .filter { !childIDs.contains($0.id) && $0.deletedAt == nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func folder(id: UUID) -> NotebookFolder? {
        folders.first { $0.id == id }
    }

    func parentFolder(of folderID: UUID) -> NotebookFolder? {
        folders.first { $0.childFolderIDs.contains(folderID) }
    }

    func rootFolder(containing folderID: UUID) -> NotebookFolder? {
        var currentID = folderID
        var visited = Set<UUID>()

        while let parent = parentFolder(of: currentID), !visited.contains(parent.id) {
            visited.insert(parent.id)
            currentID = parent.id
        }

        return folder(id: currentID)
    }

    func folderPath(to folderID: UUID) -> [NotebookFolder] {
        guard let folder = folder(id: folderID) else {
            return []
        }

        if let parent = parentFolder(of: folderID) {
            return folderPath(to: parent.id) + [folder]
        }

        return [folder]
    }

    func childFolders(of folderID: UUID?) -> [NotebookFolder] {
        guard let folderID, let folder = folder(id: folderID) else {
            return rootFolders
        }

        let childIDs = Set(folder.childFolderIDs)
        return folders
            .filter { childIDs.contains($0.id) && $0.deletedAt == nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func notes(in folderID: UUID) -> [NoteDocument] {
        guard let folder = folder(id: folderID) else {
            return []
        }

        let noteIDs = Set(folder.noteIDs)
        return notes
            .filter { noteIDs.contains($0.id) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func note(id: UUID) -> NoteDocument? {
        notes.first { $0.id == id }
    }

    func firstPage(in noteID: UUID) -> NotePage? {
        pages(in: noteID).first
    }

    func pages(in noteID: UUID) -> [NotePage] {
        guard let note = note(id: noteID) else {
            return []
        }

        let pageIDs = Set(note.pageIDs)
        return pages
            .filter { pageIDs.contains($0.id) }
            .sorted { $0.index < $1.index }
    }

    func page(id: UUID) -> NotePage? {
        pages.first { $0.id == id }
    }

    func toolPreset(id: UUID) -> DrawingToolPreset? {
        toolPresets.first { $0.id == id }
    }

    mutating func addToolPreset(
        name: String,
        kind: DrawingToolKind,
        colorHex: String,
        width: Double,
        id: UUID = UUID()
    ) -> DrawingToolPreset {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = DrawingToolPreset(
            id: id,
            name: trimmedName.isEmpty ? "New tool" : trimmedName,
            kind: kind,
            colorHex: colorHex,
            width: width
        )

        toolPresets.append(preset)
        return preset
    }

    mutating func updateToolPreset(
        id: UUID,
        name: String,
        kind: DrawingToolKind,
        colorHex: String,
        width: Double
    ) throws {
        guard let index = toolPresets.firstIndex(where: { $0.id == id }) else {
            throw LibraryMutationError.toolPresetNotFound(id)
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        toolPresets[index].name = trimmedName.isEmpty ? toolPresets[index].name : trimmedName
        toolPresets[index].kind = kind
        toolPresets[index].colorHex = colorHex
        toolPresets[index].width = min(max(width, DrawingToolPreset.minimumWidth), DrawingToolPreset.maximumWidth)
    }

    mutating func deleteCustomToolPreset(id: UUID) throws {
        guard let preset = toolPreset(id: id) else {
            throw LibraryMutationError.toolPresetNotFound(id)
        }

        guard !preset.isBuiltIn else {
            throw LibraryMutationError.cannotDeleteBuiltInToolPreset(id)
        }

        if preset.isWritingTool {
            let remainingWritingTools = toolPresets.filter { $0.id != id && $0.isWritingTool }
            guard !remainingWritingTools.isEmpty else {
                throw LibraryMutationError.cannotDeleteLastWritingToolPreset(id)
            }
        }

        toolPresets.removeAll { $0.id == id }
    }

    mutating func addFolder(
        name: String,
        colorHex: String? = nil,
        parentID: UUID? = nil,
        id: UUID = UUID()
    ) throws -> NotebookFolder {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = NotebookFolder(
            id: id,
            name: trimmedName.isEmpty ? "New folder" : trimmedName,
            colorHex: colorHex
        )

        if let parentID {
            guard let parentIndex = folders.firstIndex(where: { $0.id == parentID }) else {
                throw LibraryMutationError.folderNotFound(parentID)
            }

            folders[parentIndex].childFolderIDs.append(folder.id)
        }

        folders.append(folder)
        return folder
    }

    mutating func addNote(
        title: String,
        colorHex: String? = nil,
        folderID: UUID,
        now: Date = Date()
    ) throws -> NoteDocument {
        guard let folderIndex = folders.firstIndex(where: { $0.id == folderID }) else {
            throw LibraryMutationError.folderNotFound(folderID)
        }

        let noteID = UUID()
        let pageID = UUID()
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

        let page = NotePage(
            id: pageID,
            noteID: noteID,
            index: 0,
            format: .a4Portrait,
            template: .grid,
            drawingResourceID: "\(pageID.uuidString).drawing"
        )

        let note = NoteDocument(
            id: noteID,
            folderID: folderID,
            title: trimmedTitle.isEmpty ? "New note" : trimmedTitle,
            colorHex: colorHex,
            pageIDs: [pageID],
            createdAt: now,
            updatedAt: now
        )

        folders[folderIndex].noteIDs.append(note.id)
        notes.append(note)
        pages.append(page)

        return note
    }

    mutating func updateFolder(id: UUID, name: String, colorHex: String?) throws {
        guard let folderIndex = folders.firstIndex(where: { $0.id == id }) else {
            throw LibraryMutationError.folderNotFound(id)
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        folders[folderIndex].name = trimmedName.isEmpty ? folders[folderIndex].name : trimmedName
        folders[folderIndex].colorHex = colorHex
    }

    mutating func updateNote(id: UUID, title: String, colorHex: String?, now: Date = Date()) throws {
        guard let noteIndex = notes.firstIndex(where: { $0.id == id }) else {
            throw LibraryMutationError.noteNotFound(id)
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        notes[noteIndex].title = trimmedTitle.isEmpty ? notes[noteIndex].title : trimmedTitle
        notes[noteIndex].colorHex = colorHex
        notes[noteIndex].updatedAt = now
    }

    mutating func updatePageTemplate(pageID: UUID, template: PageTemplate) throws {
        guard let pageIndex = pages.firstIndex(where: { $0.id == pageID }) else {
            throw LibraryMutationError.pageNotFound(pageID)
        }

        pages[pageIndex].template = template
    }

    mutating func appendPage(toNoteID noteID: UUID, template: PageTemplate) throws -> NotePage {
        try insertPage(toNoteID: noteID, at: pages(in: noteID).count, template: template)
    }

    mutating func insertPage(before pageID: UUID, template: PageTemplate? = nil) throws -> NotePage {
        let referencePage = try existingPage(id: pageID)
        let insertionIndex = pages(in: referencePage.noteID).firstIndex { $0.id == pageID } ?? 0
        return try insertPage(
            toNoteID: referencePage.noteID,
            at: insertionIndex,
            template: template ?? referencePage.template
        )
    }

    mutating func insertPage(after pageID: UUID, template: PageTemplate? = nil) throws -> NotePage {
        let referencePage = try existingPage(id: pageID)
        let insertionIndex = (pages(in: referencePage.noteID).firstIndex { $0.id == pageID } ?? 0) + 1
        return try insertPage(
            toNoteID: referencePage.noteID,
            at: insertionIndex,
            template: template ?? referencePage.template
        )
    }

    mutating func duplicatePage(after pageID: UUID) throws -> NotePage {
        let sourcePage = try existingPage(id: pageID)
        let insertionIndex = (pages(in: sourcePage.noteID).firstIndex { $0.id == pageID } ?? 0) + 1
        return try insertPage(
            toNoteID: sourcePage.noteID,
            at: insertionIndex,
            format: sourcePage.format,
            template: sourcePage.template
        )
    }

    mutating func deletePage(id pageID: UUID) throws -> PageDeletionResult {
        let page = try existingPage(id: pageID)
        guard let noteIndex = notes.firstIndex(where: { $0.id == page.noteID }) else {
            throw LibraryMutationError.noteNotFound(page.noteID)
        }

        let orderedPages = pages(in: page.noteID)
        guard orderedPages.count > 1 else {
            throw LibraryMutationError.cannotDeleteLastPage(page.noteID)
        }

        let deletedIndex = orderedPages.firstIndex { $0.id == pageID } ?? 0
        let remainingPageIDs = orderedPages
            .filter { $0.id != pageID }
            .map(\.id)
        let preferredSelectionIndex = min(deletedIndex, remainingPageIDs.count - 1)

        pages.removeAll { $0.id == pageID }
        notes[noteIndex].pageIDs = remainingPageIDs
        notes[noteIndex].updatedAt = Date()
        reindexPages(for: page.noteID, orderedPageIDs: remainingPageIDs)

        return PageDeletionResult(
            drawingResourceID: page.drawingResourceID,
            preferredSelectionPageID: remainingPageIDs[preferredSelectionIndex]
        )
    }

    mutating func movePage(id pageID: UUID, toIndex targetIndex: Int) throws {
        let page = try existingPage(id: pageID)
        guard let noteIndex = notes.firstIndex(where: { $0.id == page.noteID }) else {
            throw LibraryMutationError.noteNotFound(page.noteID)
        }

        var orderedPageIDs = pages(in: page.noteID).map(\.id)
        guard let sourceIndex = orderedPageIDs.firstIndex(of: pageID) else {
            throw LibraryMutationError.pageNotFound(pageID)
        }

        orderedPageIDs.remove(at: sourceIndex)
        let boundedIndex = min(max(targetIndex, 0), orderedPageIDs.count)
        orderedPageIDs.insert(pageID, at: boundedIndex)

        notes[noteIndex].pageIDs = orderedPageIDs
        notes[noteIndex].updatedAt = Date()
        reindexPages(for: page.noteID, orderedPageIDs: orderedPageIDs)
    }

    mutating func deleteNote(id: UUID) throws -> [String] {
        guard let note = note(id: id) else {
            throw LibraryMutationError.noteNotFound(id)
        }

        let pageIDs = Set(note.pageIDs)
        let drawingResourceIDs = pages
            .filter { pageIDs.contains($0.id) }
            .map(\.drawingResourceID)

        pages.removeAll { pageIDs.contains($0.id) }
        notes.removeAll { $0.id == id }

        if let folderIndex = folders.firstIndex(where: { $0.id == note.folderID }) {
            folders[folderIndex].noteIDs.removeAll { $0 == id }
        }

        return drawingResourceIDs
    }

    mutating func deleteFolderTree(id: UUID) throws -> [String] {
        guard folder(id: id) != nil else {
            throw LibraryMutationError.folderNotFound(id)
        }

        let folderIDs = descendantFolderIDs(including: id)
        let noteIDs = Set(notes.filter { folderIDs.contains($0.folderID) }.map(\.id))
        let pageIDs = Set(pages.filter { noteIDs.contains($0.noteID) }.map(\.id))
        let drawingResourceIDs = pages
            .filter { pageIDs.contains($0.id) }
            .map(\.drawingResourceID)

        folders.removeAll { folderIDs.contains($0.id) }
        notes.removeAll { noteIDs.contains($0.id) }
        pages.removeAll { pageIDs.contains($0.id) }

        for index in folders.indices {
            folders[index].childFolderIDs.removeAll { folderIDs.contains($0) }
            folders[index].noteIDs.removeAll { noteIDs.contains($0) }
        }

        return drawingResourceIDs
    }

    mutating func moveNote(id: UUID, toFolderID targetFolderID: UUID) throws {
        guard let noteIndex = notes.firstIndex(where: { $0.id == id }) else {
            throw LibraryMutationError.noteNotFound(id)
        }

        guard let targetFolderIndex = folders.firstIndex(where: { $0.id == targetFolderID }) else {
            throw LibraryMutationError.folderNotFound(targetFolderID)
        }

        let oldFolderID = notes[noteIndex].folderID
        for index in folders.indices {
            folders[index].noteIDs.removeAll { $0 == id }
        }

        notes[noteIndex].folderID = targetFolderID
        notes[noteIndex].updatedAt = Date()

        if oldFolderID != targetFolderID || !folders[targetFolderIndex].noteIDs.contains(id) {
            folders[targetFolderIndex].noteIDs.append(id)
        }
    }

    mutating func moveFolder(id: UUID, toFolderID targetFolderID: UUID) throws {
        guard folder(id: id) != nil else {
            throw LibraryMutationError.folderNotFound(id)
        }

        guard let targetFolderIndex = folders.firstIndex(where: { $0.id == targetFolderID }) else {
            throw LibraryMutationError.folderNotFound(targetFolderID)
        }

        guard id != targetFolderID, !descendantFolderIDs(including: id).contains(targetFolderID) else {
            throw LibraryMutationError.invalidFolderMove(id, targetFolderID)
        }

        removeFolderFromParents(id: id)

        if !folders[targetFolderIndex].childFolderIDs.contains(id) {
            folders[targetFolderIndex].childFolderIDs.append(id)
        }
    }

    mutating func moveFolderToRoot(id: UUID) throws {
        guard folder(id: id) != nil else {
            throw LibraryMutationError.folderNotFound(id)
        }

        removeFolderFromParents(id: id)
    }

    func folderPathContains(folderID: UUID, candidateID: UUID) -> Bool {
        folderPath(to: folderID).contains { $0.id == candidateID }
    }

    func containsFolderCycle() -> Bool {
        let childrenByFolderID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.childFolderIDs) })
        var visited = Set<UUID>()
        var visiting = Set<UUID>()

        func visit(_ folderID: UUID) -> Bool {
            if visiting.contains(folderID) {
                return true
            }

            if visited.contains(folderID) {
                return false
            }

            visiting.insert(folderID)
            for childID in childrenByFolderID[folderID, default: []] where visit(childID) {
                return true
            }
            visiting.remove(folderID)
            visited.insert(folderID)
            return false
        }

        return folders.contains { visit($0.id) }
    }

    private func descendantFolderIDs(including folderID: UUID) -> Set<UUID> {
        guard let folder = folder(id: folderID) else {
            return []
        }

        return folder.childFolderIDs.reduce(into: Set([folderID])) { result, childID in
            result.formUnion(descendantFolderIDs(including: childID))
        }
    }

    private mutating func removeFolderFromParents(id: UUID) {
        for index in folders.indices {
            folders[index].childFolderIDs.removeAll { $0 == id }
        }
    }

    private mutating func insertPage(
        toNoteID noteID: UUID,
        at insertionIndex: Int,
        format: PageFormat = .a4Portrait,
        template: PageTemplate
    ) throws -> NotePage {
        guard let noteIndex = notes.firstIndex(where: { $0.id == noteID }) else {
            throw LibraryMutationError.noteNotFound(noteID)
        }

        let pageID = UUID()
        let page = NotePage(
            id: pageID,
            noteID: noteID,
            index: insertionIndex,
            format: format,
            template: template,
            drawingResourceID: "\(pageID.uuidString).drawing"
        )

        var orderedPageIDs = pages(in: noteID).map(\.id)
        let boundedIndex = min(max(insertionIndex, 0), orderedPageIDs.count)
        orderedPageIDs.insert(pageID, at: boundedIndex)

        pages.append(page)
        notes[noteIndex].pageIDs = orderedPageIDs
        notes[noteIndex].updatedAt = Date()
        reindexPages(for: noteID, orderedPageIDs: orderedPageIDs)

        return self.page(id: pageID) ?? page
    }

    private func existingPage(id pageID: UUID) throws -> NotePage {
        guard let page = page(id: pageID) else {
            throw LibraryMutationError.pageNotFound(pageID)
        }

        return page
    }

    private mutating func reindexPages(for noteID: UUID, orderedPageIDs: [UUID]) {
        let indexesByPageID = Dictionary(uniqueKeysWithValues: orderedPageIDs.enumerated().map { index, pageID in
            (pageID, index)
        })

        for index in pages.indices where pages[index].noteID == noteID {
            if let newIndex = indexesByPageID[pages[index].id] {
                pages[index].index = newIndex
            }
        }
    }
}

enum LibraryMutationError: Error, Equatable {
    case folderNotFound(UUID)
    case noteNotFound(UUID)
    case pageNotFound(UUID)
    case invalidFolderMove(UUID, UUID)
    case toolPresetNotFound(UUID)
    case cannotDeleteBuiltInToolPreset(UUID)
    case cannotDeleteLastWritingToolPreset(UUID)
    case cannotDeleteLastPage(UUID)
}

struct PageDeletionResult: Equatable, Sendable {
    let drawingResourceID: String
    let preferredSelectionPageID: UUID
}

extension NoteLibrarySnapshot {
    static let seed: NoteLibrarySnapshot = {
        let folderID = UUID(uuidString: "C0B6815B-F7E5-4304-91E9-89936DD8C1AE")!
        let noteID = UUID(uuidString: "F9F5A05B-153E-4A2B-9303-A4C7CF13F4D5")!
        let pageID = UUID(uuidString: "6E927823-FF62-490D-830B-08155D8FD740")!

        let page = NotePage(
            id: pageID,
            noteID: noteID,
            index: 0,
            format: .a4Portrait,
            template: .grid,
            drawingResourceID: "\(pageID.uuidString).drawing"
        )

        let note = NoteDocument(
            id: noteID,
            folderID: folderID,
            title: "Lesson 1",
            pageIDs: [pageID],
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )

        let folder = NotebookFolder(
            id: folderID,
            name: "Math",
            noteIDs: [noteID]
        )

        return NoteLibrarySnapshot(
            folders: [folder],
            notes: [note],
            pages: [page]
        )
    }()
}
