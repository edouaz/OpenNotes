import Foundation
import UIKit

struct NotebookArchive: Codable, Sendable {
    var version = 2
    var note: NoteDocument
    var pages: [NotePage]
    var resources: [String: Data]

    func validate() throws {
        guard (1...2).contains(version), !pages.isEmpty, pages.count <= 10000,
              Set(pages.map(\.id)).count == pages.count,
              note.pageIDs == pages.map(\.id), pages.allSatisfy({ $0.noteID == note.id }),
              resources.keys.allSatisfy(Self.safeResource),
              pages.allSatisfy({ Self.validText($0.pdfText) && Self.validText($0.ocrText) && resources[$0.drawingResourceID] != nil &&
                  ($0.backgroundID == nil || resources[$0.backgroundID!] != nil) &&
                  ($0.width ?? 794) > 0 && ($0.width ?? 794) <= 20000 &&
                  Self.validElements($0) &&
                  ($0.elements ?? []).allSatisfy { item in
                      item.x.isFinite && item.y.isFinite && item.width > 0 && item.width <= 20000 && item.height > 0 && item.height <= 20000 &&
                      (item.kind != .image || item.resource.flatMap { resources[$0] } != nil)
                  } &&
                  ($0.height ?? 1123) > 0 && ($0.height ?? 1123) <= 20000 }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }
    static func validElements(_ page: NotePage) -> Bool {
        let elements = page.elements ?? []
        let action = DocumentAction(pageID: page.id, kind: .setElements, elements: elements)
        return DocumentAction.validHierarchy(elements) && elements.allSatisfy { action.valid($0, on: page) }
    }
    static func validText(_ content: PageTextContent?) -> Bool {
        guard let content else { return true }
        return content.text.count <= 5_000_000 && content.blocks.count <= 100_000 && content.blocks.allSatisfy { block in
            block.x.isFinite && block.y.isFinite && block.width.isFinite && block.height.isFinite &&
            block.width > 0 && block.height > 0 && block.width <= 20000 && block.height <= 20000 &&
            abs(block.x) <= 20000 && abs(block.y) <= 20000 &&
            (block.confidence == nil || (block.confidence!.isFinite && (0...1).contains(block.confidence!)))
        }
    }
    static func safeResource(_ name: String) -> Bool {
        !name.isEmpty && name.count < 128 && name != "." && name != ".." &&
        name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_ ")).contains($0) }
    }
}

actor DiskStore {
    private var checkedInkBackups: Set<String> = []
    private var stagedDrawingResources: Set<String> = []
    private var renderingThumbnail = false
    private var thumbnailWaiters: [CheckedContinuation<Void, Never>] = []
    private func acquireThumbnailRenderer() async {
        if renderingThumbnail { await withCheckedContinuation { thumbnailWaiters.append($0) } }
        else { renderingThumbnail = true }
    }
    private func releaseThumbnailRenderer() {
        if thumbnailWaiters.isEmpty { renderingThumbnail = false }
        else { thumbnailWaiters.removeFirst().resume() }
    }
    private var thumbnails: [Data: UIImage] = [:]
    private var resourceGeneration: [String: Int] = [:]
    private var thumbnailOrder: [Data] = []
    private var thumbnailBytes = 0
    let root: URL
    init(root: URL) { self.root = root }
    private var pdfDocuments: [String: (generation: Int, document: CGPDFDocument)] = [:]
    private func pdfDocument(_ name: String) throws -> CGPDFDocument? {
        let generation = resourceGeneration[name, default: 0]
        if let cached = pdfDocuments[name], cached.generation == generation { return cached.document }
        guard let data = try read(name), let document = CGDataProvider(data: data as CFData).flatMap(CGPDFDocument.init) else { return nil }
        if pdfDocuments.count >= 3, let evicted = pdfDocuments.keys.first { pdfDocuments[evicted] = nil }
        pdfDocuments[name] = (generation, document)
        return document
    }
    func thumbnail(_ page: NotePage, pixels requestedPixels: Int = 160) async throws -> UIImage {
        let pixels = min(1600, max(80, requestedPixels))
        await acquireThumbnailRenderer()
        defer { releaseThumbnailRenderer() }
        try Task.checkCancellation()
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        var key = try encoder.encode(page)
        let names = Set([page.drawingResourceID] + [page.backgroundID].compactMap { $0 } + (page.elements ?? []).compactMap(\.resource)).sorted()
        let generations = names.map { resourceGeneration[$0, default: 0] }
        key.append(try encoder.encode(generations)); key.append(Data("pixels:\(pixels)".utf8))
        if let cached = thumbnails[key] { return cached }
        let drawing = try read(page.drawingResourceID)
        var resources: [String: Data] = [:]
        for item in page.elements ?? [] { if let name = item.resource { resources[name] = try read(name) } }
        // PDF pages reuse one parsed document per resource instead of re-reading and re-parsing the whole file per thumbnail.
        let pdfPage = try page.pdfIndex.flatMap { index in try page.backgroundID.flatMap { try pdfDocument($0)?.page(at: index + 1) } }
        let background = pdfPage == nil ? try page.backgroundID.flatMap { try read($0) } : nil
        let work = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let rendered = PageRenderer.image(page, data: background, drawing: try drawing.map(InkDrawing.init(data:)), resources: resources, pdfPage: pdfPage, scale: CGFloat(pixels) / max(PageRenderer.size(page).width, PageRenderer.size(page).height))
            guard let pixels = rendered.cgImage else { throw CocoaError(.fileReadCorruptFile) }
            // iOS 16 CoreUI rejects sub-1x UIImage scales when SwiftUI registers an image asset.
            return UIImage(cgImage: pixels, scale: 1, orientation: .up)
        }
        let image = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        try Task.checkCancellation()
        guard generations == names.map({ resourceGeneration[$0, default: 0] }) else { return image }
        let bytes = (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)
        while thumbnailBytes + bytes > 16_000_000, !thumbnailOrder.isEmpty {
            let oldest = thumbnailOrder.removeFirst()
            if let removed = thumbnails.removeValue(forKey: oldest) { thumbnailBytes -= (removed.cgImage?.bytesPerRow ?? 0) * (removed.cgImage?.height ?? 0) }
        }
        if let cached = thumbnails[key] { return cached }
        if bytes <= 16_000_000 { thumbnails[key] = image; thumbnailOrder.append(key); thumbnailBytes += bytes }
        return image
    }
    func clearThumbnails() { pdfDocuments.removeAll(); thumbnails.removeAll(); thumbnailOrder.removeAll(); thumbnailBytes = 0 }
    func load() throws -> NoteLibrarySnapshot {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let journal = root.appendingPathComponent("library.pending.json")
        if FileManager.default.fileExists(atPath: journal.path) {
            let data = try Data(contentsOf: journal)
            let pending = try JSONDecoder().decode(NoteLibrarySnapshot.self, from: data)
            try validate(pending)
            for page in pending.pages {
                guard let data = try read(page.drawingResourceID) else { throw CocoaError(.fileNoSuchFile) }
                _ = try InkDrawing(data: data)
                for name in [page.backgroundID].compactMap({ $0 }) + (page.elements ?? []).compactMap(\.resource) {
                    guard try read(name) != nil else { throw CocoaError(.fileNoSuchFile) }
                }
            }
            try data.write(to: root.appendingPathComponent("library.json"), options: .atomic)
            try FileManager.default.removeItem(at: journal)
            return pending
        }
        let url = root.appendingPathComponent("library.json")
        if !FileManager.default.fileExists(atPath: url.path) {
            return NoteLibrarySnapshot(folders: [NotebookFolder(id: NotebookFolder.homeID, name: "My notebooks")])
        }
        // Never replace a corrupt library with an empty one.
        let library = try JSONDecoder().decode(NoteLibrarySnapshot.self, from: Data(contentsOf: url))
        try validate(library); return library
    }
    func validate(_ library: NoteLibrarySnapshot) throws {
        let pagesByID = Dictionary(library.pages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard library.schemaVersion == 1, !library.folders.isEmpty,
              Set(library.notes.map(\.id)).count == library.notes.count,
              Set(library.pages.map(\.id)).count == library.pages.count,
              !library.containsFolderCycle(),
              library.notes.allSatisfy({ note in
                  // Equivalent to pages(in:) but O(note pages) instead of a library-wide scan per note (ids are unique here).
                  !note.pageIDs.isEmpty && note.pageIDs == note.pageIDs.compactMap({ pagesByID[$0] }).sorted(by: { $0.index < $1.index }).map(\.id) &&
                  Set(note.pageIDs).count == note.pageIDs.count && library.folder(id: note.folderID) != nil
              }),
              library.pages.allSatisfy({ NotebookArchive.validElements($0) && NotebookArchive.validText($0.pdfText) && NotebookArchive.validText($0.ocrText) && NotebookArchive.safeResource($0.drawingResourceID) && ($0.backgroundID == nil || NotebookArchive.safeResource($0.backgroundID!)) }) else { throw CocoaError(.fileReadCorruptFile) }
    }
    // What this store last wrote to library.json. When the file on disk is byte-identical it is known-valid,
    // so the autosave path skips two full library decodes (backup validation and revision pruning).
    private var lastWritten: (data: Data, resources: Set<String>)?
    func save(_ library: NoteLibrarySnapshot) throws {
        try validate(library)
        let url = root.appendingPathComponent("library.json")
        let journal = root.appendingPathComponent("library.pending.json")
        let data = try JSONEncoder().encode(library)
        try data.write(to: journal, options: .atomic)
        var previousResources: Set<String>?
        if let old = try? Data(contentsOf: url) {
            if let known = lastWritten, known.data == old { previousResources = known.resources }
            else { previousResources = Set(try JSONDecoder().decode(NoteLibrarySnapshot.self, from: old).pages.map(\.drawingResourceID)) }
            try old.write(to: root.appendingPathComponent("library.backup.json"), options: .atomic)
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.removeItem(at: journal)
        lastWritten = (data, Set(library.pages.map(\.drawingResourceID)))
        stagedDrawingResources.subtract(library.pages.map(\.drawingResourceID))
        pruneDrawingRevisions(library, backupResources: previousResources)
    }
    func writeDrawingRevision(_ data: Data) throws -> String {
        let name = "ink-revision-\(UUID().uuidString).drawing"
        try write(data, name: name)
        stagedDrawingResources.insert(name)
        return name
    }
    private func pruneDrawingRevisions(_ library: NoteLibrarySnapshot, backupResources: Set<String>?) {
        var retained = Set(library.pages.map(\.drawingResourceID)).union(stagedDrawingResources)
        if let backupResources { retained.formUnion(backupResources) }
        else if FileManager.default.fileExists(atPath: root.appendingPathComponent("library.backup.json").path) {
            // No fresh backup written this save: fall back to reading the existing one.
            guard let data = try? Data(contentsOf: root.appendingPathComponent("library.backup.json")),
                  let backup = try? JSONDecoder().decode(NoteLibrarySnapshot.self, from: data) else { return }
            retained.formUnion(backup.pages.map(\.drawingResourceID))
        }
        let resources = root.appendingPathComponent("resources")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: resources.path)) ?? []
            where name.hasPrefix("ink-revision-") && name.hasSuffix(".drawing") && !retained.contains(name) {
            try? FileManager.default.removeItem(at: resources.appendingPathComponent(name))
        }
    }
    func restoreBackup() throws -> NoteLibrarySnapshot {
        let data = try Data(contentsOf: root.appendingPathComponent("library.backup.json"))
        let library = try JSONDecoder().decode(NoteLibrarySnapshot.self, from: data)
        try validate(library)
        try data.write(to: root.appendingPathComponent("library.json"), options: .atomic)
        let journal = root.appendingPathComponent("library.pending.json")
        if FileManager.default.fileExists(atPath: journal.path) { try FileManager.default.removeItem(at: journal) }
        return library
    }
    func read(_ name: String) throws -> Data? {
        guard NotebookArchive.safeResource(name) else { throw CocoaError(.fileReadInvalidFileName) }
        let url = root.appendingPathComponent("resources").appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }
    func write(_ data: Data, name: String) throws {
        guard NotebookArchive.safeResource(name) else { throw CocoaError(.fileWriteInvalidFileName) }
        let folder = root.appendingPathComponent("resources")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(name)
        if name.hasSuffix(".drawing"), !checkedInkBackups.contains(name) {
            if FileManager.default.fileExists(atPath: destination.path) {
                let previous = try Data(contentsOf: destination)
                if let document = try? JSONSerialization.jsonObject(with: previous) as? [String: Any],
                   document["inkSchemaVersion"] as? Int == 1 {
                    let backups = root.appendingPathComponent("ink-schema-backups")
                    try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
                    let backup = backups.appendingPathComponent(name)
                    if !FileManager.default.fileExists(atPath: backup.path) { try previous.write(to: backup, options: .atomic) }
                }
                checkedInkBackups.insert(name)
            }
        }
        try data.write(to: destination, options: .atomic)
        resourceGeneration[name, default: 0] += 1
    }
    func archive(note: NoteDocument, pages: [NotePage]) throws -> NotebookArchive {
        var resources: [String: Data] = [:]
        for page in pages {
            guard let drawing = try read(page.drawingResourceID) else { throw CocoaError(.fileNoSuchFile) }
            resources[page.drawingResourceID] = drawing
            for element in page.elements ?? [] {
                if let name = element.resource, resources[name] == nil {
                    guard let data = try read(name) else { throw CocoaError(.fileNoSuchFile) }
                    resources[name] = data
                }
            }
            if let name = page.backgroundID, resources[name] == nil {
                guard let data = try read(name) else { throw CocoaError(.fileNoSuchFile) }
                resources[name] = data
            }
        }
        let archive = NotebookArchive(note: note, pages: pages, resources: resources)
        try archive.validate()
        return archive
    }
}
