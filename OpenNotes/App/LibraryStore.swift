import SwiftUI
import UIKit
import PDFKit

@MainActor
final class LibraryStore: ObservableObject {
    @Published var library = NoteLibrarySnapshot()
    @Published var error: String?
    @Published var ready = false
    @Published var saving = false
    lazy var cloud = CloudSync(store: self)
    let disk: DiskStore
    let root: URL
    private var editors: [UUID: () -> EditorSession?] = [:]
    func register(_ editor: EditorSession) {
        editors = editors.filter { $0.value() != nil }
        editors[UUID()] = { [weak editor] in editor }
    }
    func flushEditors(for noteID: UUID, allowInteraction: Bool = false) async -> Bool {
        for editor in editors.values.compactMap({ $0() }) where editor.noteID == noteID {
            guard allowInteraction || !editor.cloudInteractionActive else { return false }
            guard await editor.flush() else { return false }
        }
        return await flush()
    }
    private var loadTask: Task<NoteLibrarySnapshot, Error>?
    private var saveGeneration = 0
    private var saveFailed = false
    private var saveTask: Task<Void, Never>?
    // Keep the legacy directory so an in-place upgrade preserves existing notebooks.
    init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CatNotes")) {
        disk = DiskStore(root: root)
        self.root = root
    }
    func load() async {
        guard !ready else { return }
        Diagnostics.shared.record("library.load.begin")
        let task = loadTask ?? Task { try await disk.load() }
        loadTask = task
        defer { loadTask = nil }
        do {
            var loaded = try await task.value
            let adopted = loaded.adoptSharedHomeFolder()
            if adopted { Diagnostics.shared.record("library.home.adopted", ["notes": String(loaded.folders.first?.noteIDs.count ?? 0)]) }
            if !ready { library = loaded; ready = true; if adopted { persist() }; cloud.start(); Diagnostics.shared.record("library.load.ready", ["notes": String(loaded.notes.count), "pages": String(loaded.pages.count)]) }
        } catch { Diagnostics.shared.failure("library.failure", error: error); self.error = "Could not open: \(error.localizedDescription)" }
    }
    /// Deletes every notebook and resource on this device and starts from an empty library. Caller has already cleared the cloud.
    func resetLocal() async throws {
        guard await flush() else { throw CocoaError(.fileWriteUnknown) }
        for name in try FileManager.default.contentsOfDirectory(atPath: root.path) where name != "cloud-state.json" {
            try FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }
        library = try await disk.load()
        persist()
        guard await flush() else { throw CocoaError(.fileWriteUnknown) }
    }
    func restore() async {
        do { library = try await disk.restoreBackup(); ready = true }
        catch { Diagnostics.shared.failure("library.failure", error: error); self.error = error.localizedDescription }
    }
    func persist() {
        cloud.localChangesWillSave()
        let snapshot = library
        saveGeneration += 1
        let generation = saveGeneration
        let previous = saveTask
        if !saving { saving = true }   // each publish re-renders every view observing the store
        saveTask = Task {
            await previous?.value
            do { try await disk.save(snapshot); self.saveFailed = false; cloud.localChangesDidSave(); Diagnostics.shared.record("library.save.ok", ["generation": String(generation)]) }
            catch { Diagnostics.shared.failure("library.save.failure", error: error); self.saveFailed = true; cloud.localSaveFailed(); self.error = "Could not save: \(error.localizedDescription)" }
            if generation == saveGeneration { self.saving = false }
        }
    }
    @discardableResult func flush() async -> Bool {
        if saveFailed && !saving { persist() }
        while let task = saveTask {
            let generation = saveGeneration
            await task.value
            if generation == saveGeneration { return !saveFailed }
        }
        return !saveFailed
    }
    func create(title: String = "New notebook", folderID: UUID? = nil) async -> UUID? {
        do {
            let initial = library
            var snapshot = initial
            let note = try snapshot.addNote(title: title, folderID: folderID ?? snapshot.folders[0].id)
            var page = snapshot.pages(in: note.id)[0]
            AppPreferences.applyDefaultStyle(to: &page)
            if let index = snapshot.pages.firstIndex(where: { $0.id == page.id }) { snapshot.pages[index] = page }
            try await disk.write(InkDrawing().dataRepresentation(), name: page.drawingResourceID)
            guard library == initial else { throw CocoaError(.userCancelled) }
            library = snapshot; persist()
            return note.id
        } catch { Diagnostics.shared.failure("library.failure", error: error); self.error = error.localizedDescription; return nil }
    }
    func matchingNotes(_ query: String, trash: Bool = false, favorites: Bool = false) -> [NoteDocument] {
        // One pass over all pages (not one library-wide page scan per note).
        let textHits: Set<UUID> = query.isEmpty ? [] : Set(library.pages.lazy.filter { $0.matches(query) }.map(\.noteID))
        return library.notes.filter { note in
            note.purgedAt == nil && (note.deletedAt != nil) == trash && (!favorites || note.favorite == true) &&
            (query.isEmpty || note.title.localizedCaseInsensitiveContains(query) || textHits.contains(note.id))
        }.sorted { $0.updatedAt > $1.updatedAt }
    }
    func trashFolder(_ id: UUID) {
        guard id != library.folders.first?.id, library.folder(id: id) != nil else { return }
        let descendants = Set(library.folders.filter { library.folderPathContains(folderID: $0.id, candidateID: id) }.map(\.id))
        let now = Date()
        for index in library.folders.indices where descendants.contains(library.folders[index].id) {
            library.folders[index].deletedAt = library.folders[index].deletedAt ?? now
        }
        for index in library.notes.indices where descendants.contains(library.notes[index].folderID) && library.notes[index].deletedAt == nil {
            library.notes[index].deletedAt = now; library.notes[index].updatedAt = now
        }
        persist()
    }
    func restoreNote(_ id: UUID) {
        guard let note = library.note(id: id), note.purgedAt == nil else { return }
        if library.folderPath(to: note.folderID).contains(where: { $0.deletedAt != nil }), let root = library.folders.first(where: { $0.deletedAt == nil }) {
            do { try library.moveNote(id: id, toFolderID: root.id) }
            catch { self.error = error.localizedDescription; return }
        }
        update(id) { $0.deletedAt = nil }
    }
    func emptyTrash() {
        let now = Date()
        // Keep a synced marker so another device cannot download the emptied Trash again.
        for index in library.notes.indices where library.notes[index].deletedAt != nil && library.notes[index].purgedAt == nil {
            library.notes[index].purgedAt = now; library.notes[index].updatedAt = now
        }
        persist()
    }
    func update(_ id: UUID, change: (inout NoteDocument) -> Void) {
        guard let i = library.notes.firstIndex(where: { $0.id == id }) else { return }
        change(&library.notes[i]); library.notes[i].updatedAt = Date(); persist()
    }
    func updatePage(_ page: NotePage) {
        guard let i = library.pages.firstIndex(where: { $0.id == page.id }) else { return }
        var page = page
        page.modifiedAt = Date()
        page.revision = (library.pages[i].revision ?? 0) + 1
        library.pages[i] = page
        update(page.noteID) { _ in }
    }
    func addPage(noteID: UUID, after: UUID?, duplicate: Bool = false) async -> UUID? {
        do {
            let initial = library
            var snapshot = initial
            var page: NotePage
            if let after, duplicate {
                var copy = try snapshot.duplicatePage(after: after)
                if let source = library.page(id: after) {
                    copy.backgroundID = source.backgroundID; copy.pdfIndex = source.pdfIndex
                    copy.width = source.width; copy.height = source.height
                    copy.elements = source.elements
                    copy.text = source.text; copy.recognizedText = source.recognizedText
                    copy.pdfText = source.pdfText; copy.ocrText = source.ocrText; copy.drawingRevision = source.drawingRevision
                    snapshot.pages[snapshot.pages.firstIndex(where: { $0.id == copy.id })!] = copy
                    guard let data = try await disk.read(source.drawingResourceID) else { throw CocoaError(.fileNoSuchFile) }
                    try await disk.write(data, name: copy.drawingResourceID)
                }
                page = copy
            } else {
                // After a PDF or image page, and at the end, a new page takes the default style; otherwise it continues its neighbour.
                let styled = after.flatMap { library.page(id: $0) }.map { $0.backgroundID != nil } ?? true
                if let after { page = try snapshot.insertPage(after: after) }
                else { page = try snapshot.appendPage(toNoteID: noteID, template: AppPreferences.defaultTemplate) }
                if styled, let index = snapshot.pages.firstIndex(where: { $0.id == page.id }) {
                    AppPreferences.applyDefaultStyle(to: &page); snapshot.pages[index] = page
                }
                try await disk.write(InkDrawing().dataRepresentation(), name: page.drawingResourceID)
            }
            guard library == initial else { throw CocoaError(.userCancelled) }
            library = snapshot; persist(); return page.id
        } catch { Diagnostics.shared.failure("library.failure", error: error); self.error = error.localizedDescription; return nil }
    }
    func indexPDFText(in noteID: UUID) async {
        let candidates = library.pages(in: noteID).filter { $0.pdfIndex != nil && $0.pdfText == nil }
        for name in Set(candidates.compactMap(\.backgroundID)) {
            do {
                guard let data = try await disk.read(name) else { throw CocoaError(.fileNoSuchFile) }
                let indexed = try await Task.detached(priority: .utility) { try PDFTextIndex.extract(data) }.value
                for candidate in candidates where candidate.backgroundID == name {
                    guard var current = library.page(id: candidate.id), current.backgroundID == name,
                          let index = current.pdfIndex, indexed.indices.contains(index), current.pdfText == nil else { continue }
                    current.pdfText = indexed[index]
                    if let position = library.pages.firstIndex(where: { $0.id == current.id }) { library.pages[position] = current }
                }
                persist()
            } catch { Diagnostics.shared.failure("library.failure", error: error); self.error = "Reading PDF text: \(error.localizedDescription)" }
        }
    }
    func apply(_ action: DocumentAction) async throws {
        let elements = action.kind == .setElements ? action.elements ?? [] : [action.element].compactMap { $0 }
        for element in elements where element.kind == .image {
            guard let name = element.resource, try await disk.read(name) != nil else { throw CocoaError(.fileNoSuchFile) }
        }
        guard let current = library.page(id: action.pageID) else { throw CocoaError(.fileNoSuchFile) }
        updatePage(try action.applying(to: current))
    }
    @discardableResult func apply(_ action: LibraryAction) -> UUID? {
        do { let result = try action.apply(to: &library); persist(); return result }
        catch { Diagnostics.shared.failure("library.failure", error: error); self.error = error.localizedDescription; return nil }
    }
    func removePage(_ id: UUID) -> UUID? {
        do { let result = try library.deletePage(id: id); persist(); return result.preferredSelectionPageID }
        catch { Diagnostics.shared.failure("library.failure", error: error); self.error = error.localizedDescription; return nil }
    }
    func movePage(_ id: UUID, index: Int) {
        do { try library.movePage(id: id, toIndex: index); persist() }
        catch { Diagnostics.shared.failure("library.failure", error: error); self.error = error.localizedDescription }
    }
    func importFile(_ url: URL, folderID: UUID? = nil) async -> UUID? {
        Diagnostics.shared.record("library.import.begin")
        if !ready { await load() }
        guard ready else { return nil }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try await Task.detached { try Data(contentsOf: url, options: .mappedIfSafe) }.value
            guard data.count <= 150_000_000 else { throw CocoaError(.fileReadTooLarge) }
            if url.pathExtension.lowercased() == "catnote" {
                let archive = try await Task.detached(priority: .userInitiated) { try JSONDecoder().decode(NotebookArchive.self, from: data) }.value
                return try await importArchive(archive, folderID: folderID)
            }
            let pdf = PDFDocument(data: data)
            let image = pdf == nil ? UIImage(data: data) : nil
            guard (pdf != nil && !(pdf!.isLocked) && pdf!.pageCount > 0) || image != nil else { throw CocoaError(.fileReadCorruptFile) }
            let extracted = pdf != nil ? try await Task.detached(priority: .utility) { try PDFTextIndex.extract(data) }.value : []
            let initial = library
            var snapshot = initial
            let note = try snapshot.addNote(title: url.deletingPathExtension().lastPathComponent, folderID: folderID ?? snapshot.folders[0].id)
            let asset = UUID().uuidString + (pdf != nil ? ".pdf" : ".image")
            try await disk.write(data, name: asset)
            for index in 0..<(pdf?.pageCount ?? 1) {
                var page = index == 0 ? snapshot.pages(in: note.id)[0] : try snapshot.appendPage(toNoteID: note.id, template: .blank)
                var size = pdf?.page(at: index)?.bounds(for: .cropBox).size ?? image!.size
                if let rotation = pdf?.page(at: index)?.rotation, abs(rotation) % 180 == 90 { size = CGSize(width: size.height, height: size.width) }
                page.pdfText = extracted.indices.contains(index) ? extracted[index] : nil
                page.template = .blank; page.backgroundID = asset; page.pdfIndex = pdf != nil ? index : nil
                page.width = size.width; page.height = size.height
                snapshot.pages[snapshot.pages.firstIndex(where: { $0.id == page.id })!] = page
                try await disk.write(InkDrawing().dataRepresentation(), name: page.drawingResourceID)
            }
            guard library == initial else { throw CocoaError(.userCancelled) }
            library = snapshot; persist(); return note.id
        } catch { Diagnostics.shared.failure("library.failure", error: error); self.error = error.localizedDescription; return nil }
    }
    func importArchive(_ archive: NotebookArchive, folderID: UUID? = nil) async throws -> UUID {
        try await Task.detached(priority: .utility) {
            try archive.validate()
            for page in archive.pages { _ = try InkDrawing(data: archive.resources[page.drawingResourceID]!) }
        }.value
        // Imported archives receive fresh identifiers so they can never overwrite a local notebook.
        let initial = library
        var snapshot = initial
        let note = try snapshot.addNote(title: archive.note.title, folderID: folderID ?? snapshot.folders[0].id)
        snapshot.pages.removeAll { $0.noteID == note.id }
        var imported: [NotePage] = []
        var names: [String: String] = [:]
        for (name, data) in archive.resources {
            let newName = UUID().uuidString + "." + URL(fileURLWithPath: name).pathExtension
            names[name] = newName; try await disk.write(data, name: newName)
        }
        for source in archive.pages {
            var page = NotePage(noteID: note.id, index: imported.count, format: source.format, template: source.template, drawingResourceID: names[source.drawingResourceID]!)
            page.backgroundID = source.backgroundID.flatMap { names[$0] }; page.pdfIndex = source.pdfIndex
            page.width = source.width; page.height = source.height; page.text = source.text
            page.recognizedText = source.recognizedText; page.bookmark = source.bookmark
            page.pdfText = source.pdfText; page.ocrText = source.ocrText; page.drawingRevision = source.drawingRevision; page.modifiedAt = source.modifiedAt
            page.elements = source.elements?.map { source in var item = source; item.resource = source.resource.flatMap { names[$0] }; return item }
            imported.append(page)
        }
        snapshot.pages.append(contentsOf: imported)
        let i = snapshot.notes.firstIndex(where: { $0.id == note.id })!
        snapshot.notes[i].pageIDs = imported.map(\.id)
        snapshot.notes[i].favorite = archive.note.favorite
        snapshot.notes[i].deletedAt = archive.note.deletedAt
        guard library == initial else { throw CocoaError(.userCancelled) }
        library = snapshot; persist(); return note.id
    }
    func archive(_ id: UUID, indices: ClosedRange<Int>? = nil) async throws -> NotebookArchive {
        guard await flushEditors(for: id, allowInteraction: true) else { throw CocoaError(.fileWriteUnknown) }
        guard let note = library.note(id: id) else { throw CocoaError(.fileNoSuchFile) }
        var selected = library.pages(in: id)
        var exportNote = note
        if let indices {
            guard indices.lowerBound >= 0, indices.upperBound < selected.count else { throw CocoaError(.validationMissingMandatoryProperty) }
            selected = Array(selected[indices]); exportNote.pageIDs = selected.map(\.id)
        }
        return try await disk.archive(note: exportNote, pages: selected)
    }
    func applyCloudArchive(_ archive: NotebookArchive, expected: NoteDocument?) async throws -> UUID {
        try await Task.detached(priority: .utility) {
            try archive.validate()
            for page in archive.pages {
                guard let data = archive.resources[page.drawingResourceID] else { throw CocoaError(.fileReadCorruptFile) }
                _ = try InkDrawing(data: data)
            }
        }.value
        let initial = library
        let active = editors.values.compactMap { $0() }.filter { $0.noteID == archive.note.id }
        guard library.note(id: archive.note.id) == expected,
              active.allSatisfy({ !$0.cloudInteractionActive && !$0.cloudHasUnsavedEdits }),
              !library.pages.contains(where: { $0.noteID != archive.note.id && archive.note.pageIDs.contains($0.id) }) else { throw CocoaError(.userCancelled) }
        var names: [String: String] = [:]
        let drawings = Set(archive.pages.map(\.drawingResourceID))
        for (name, data) in archive.resources {
            if drawings.contains(name) {
                names[name] = try await disk.writeDrawingRevision(data)
            } else {
                let target = UUID().uuidString + "." + URL(fileURLWithPath: name).pathExtension
                try await disk.write(data, name: target); names[name] = target
            }
        }
        let currentEditors = editors.values.compactMap { $0() }.filter { $0.noteID == archive.note.id }
        guard library == initial, currentEditors.allSatisfy({ !$0.cloudInteractionActive && !$0.cloudHasUnsavedEdits }) else { throw CocoaError(.userCancelled) }
        var snapshot = initial
        if snapshot.folder(id: archive.note.folderID) == nil {
            snapshot.folders.append(NotebookFolder(id: archive.note.folderID, name: "Imported folder"))
        }
        snapshot.notes.removeAll { $0.id == archive.note.id }; snapshot.notes.append(archive.note)
        snapshot.pages.removeAll { $0.noteID == archive.note.id }
        snapshot.pages.append(contentsOf: archive.pages.map { source in
            var page = source
            page.drawingResourceID = names[source.drawingResourceID]!
            page.backgroundID = source.backgroundID.flatMap { names[$0] }
            page.elements = source.elements?.map { source in var item = source; item.resource = source.resource.flatMap { names[$0] }; return item }
            return page
        })
        for index in snapshot.folders.indices {
            snapshot.folders[index].noteIDs.removeAll { $0 == archive.note.id }
            if snapshot.folders[index].id == archive.note.folderID { snapshot.folders[index].noteIDs.append(archive.note.id) }
        }
        let readOnly = currentEditors.map(\.isReadOnly)
        let inputs = currentEditors.flatMap(\.cloudInputViews).map { ($0, $0.isUserInteractionEnabled) }
        for (view, _) in inputs { view.isUserInteractionEnabled = false }
        for editor in currentEditors { editor.cloudInstalling = true; editor.isReadOnly = true }
        defer {
            for (editor, value) in zip(currentEditors, readOnly) { editor.isReadOnly = value; editor.cloudInstalling = false }
            for (view, value) in inputs { view.isUserInteractionEnabled = value }
        }
        library = snapshot; persist()
        let saved = await flush()
        for editor in currentEditors { await editor.reloadFromCloud() }
        guard saved else { throw CocoaError(.fileWriteUnknown) }
        return archive.note.id
    }
}
