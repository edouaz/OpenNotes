import Combine
import SwiftUI
import UIKit
import Vision

@MainActor
final class EditorSession: ObservableObject {
    @Published var page: NotePage?
    var drawing = InkDrawing()
    @Published var searchHighlights: [CGRect] = []
    @Published var background: UIImage?
    @Published var dirty = false
    @Published var busy = false
    @Published var stickyInsertionColor: String?
    /// Objects of the current lasso or tap selection; nil when there is none (see `selectionSnapshot`).
    var selectionIDs: SelectionIdentity?
    @discardableResult func insertSticky(at point: CGPoint, color override: String? = nil) async -> Bool {
        pendingDocumentActions += 1; defer { pendingDocumentActions -= 1 }
        guard !isReadOnly, let color = override ?? stickyInsertionColor, let page, point.x.isFinite, point.y.isFinite else { return false }
        var note = PageElement(kind: .stickyNote)
        note.text = ""; note.fillColorHex = color
        if toolSettings.stickyCard == true { note.applyCardStyle() }
        let size = PageRenderer.size(page)
        note.width = min(220, size.width); note.height = min(180, size.height)
        note.x = min(max(0, point.x), size.width - note.width)
        note.y = min(max(0, point.y), size.height - note.height)
        guard await apply(.init(pageID: page.id, kind: .upsertElement, element: note)) else { return false }
        stickyInsertionColor = nil
        return true
    }
    @Published var isReadOnly = false {
        willSet { if newValue { commitStickyEdits() } }
        didSet { if isReadOnly { stickyInsertionColor = nil; canvas.cancelActiveStroke() } }
    }
    private var stickyDrafts: [UUID: PageElement] = [:]
    // Selection edits are as durable as pen strokes: the autosave persists them, so the UI need not wait for disk.
    // Pending sticky text drafts must still be committed first.
    func prepareEdit(durable: Bool) async -> Bool {
        durable || !stickyDrafts.isEmpty ? await flush() : true
    }
    func stageStickyEdit(_ note: PageElement) {
        guard !isReadOnly, page?.elements?.contains(where: { $0.id == note.id && $0.isLocked != true }) == true else { return }
        stickyDrafts[note.id] = note
        autosave?.cancel()
        autosave = Task {
            do { try await Task.sleep(nanoseconds: 700_000_000) } catch { return }
            _ = await flush()
        }
    }
    var pageIncludingDrafts: NotePage? {
        guard var page else { return nil }
        page.elements = page.elements?.map { stickyDrafts[$0.id] ?? $0 }
        return page
    }
    private func commitStickyEdits() {
        guard !stickyDrafts.isEmpty, let page else { return }
        let drafts = stickyDrafts
        stickyDrafts = [:]
        let elements = (page.elements ?? []).map { drafts[$0.id] ?? $0 }
        if elements != (page.elements ?? []) { replaceContent(drawing, elements: elements, actionName: "Edit sticky text") }
        if error != nil { stickyDrafts.merge(drafts) { _, draft in draft } }
    }
    private(set) var previousWritingTool = DrawingToolKind.pen
    func finishErasing() {
        if toolSettings.eraserAutoDeselect == true { selectedTool = previousWritingTool }
    }
    @discardableResult func clearPage() async -> Bool {
        pendingDocumentActions += 1; defer { pendingDocumentActions -= 1 }
        guard !isReadOnly, await flush(), page != nil else { return false }
        replaceContent(InkDrawing(), elements: [], actionName: "Clear page")
        return await flush()
    }
    @Published var error: String?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    let canvas = InkCanvasView()
    var canvasPageID: UUID?
    func refreshUndoAvailability() {
        let undo = canvas.undoManager
        let undoAvailable = undo?.canUndo == true, redoAvailable = undo?.canRedo == true
        if canUndo != undoAvailable { canUndo = undoAvailable }
        if canRedo != redoAvailable { canRedo = redoAvailable }
    }
    private let preferences: UserDefaults
    private var restoringTool = false
    private var instrumentPresets: [DrawingToolPreset] = []
    @Published var toolSettings = EditorToolSettings() {
        didSet { preferences.set(try? JSONEncoder().encode(toolSettings), forKey: "editorToolSettings") }
    }
    func setFavoriteColors(_ colors: [String]) {
        guard colors.count <= 64, colors.allSatisfy({ UIColor(presetHex: $0) != nil }) else { return }
        toolSettings.setColors(colors, for: selectedTool)
    }
    @Published var selectedTool = DrawingToolKind.pen {
        didSet {
            guard oldValue != selectedTool else { return }
            if oldValue.isWritingTool { previousWritingTool = oldValue }
            Diagnostics.shared.record("tool.selected", ["kind": selectedTool.rawValue])
            preferences.set(selectedTool.rawValue, forKey: "inkTool")
            restoreInstrument()
            if let index = toolSettings.selectedStrokePresets?[selectedTool.rawValue] { selectStrokePreset(index) }
        }
    }
    @Published var inkColor = Color.black { didSet { saveInstrument() } }
    @Published var inkWidth = 3.0 { didSet { saveInstrument() } }
    private func restoreInstrument() {
        guard let preset = instrumentPresets.first(where: { $0.kind == selectedTool }) else { return }
        restoringTool = true
        inkColor = Color(UIColor(presetHex: preset.colorHex) ?? .black)
        inkWidth = preset.width
        restoringTool = false
    }
    private func saveInstrument() {
        guard !restoringTool, inkWidth.isFinite, inkWidth > 0,
              let index = instrumentPresets.firstIndex(where: { $0.kind == selectedTool }) else { return }
        instrumentPresets[index].colorHex = UIColor(inkColor).presetHex
        instrumentPresets[index].width = min(DrawingToolPreset.maximumWidth, max(DrawingToolPreset.minimumWidth, inkWidth))
        preferences.set(try? JSONEncoder().encode(instrumentPresets), forKey: "instrumentPresets")
        preferences.set(inkWidth, forKey: "inkWidth")
        preferences.set(try? NSKeyedArchiver.archivedData(withRootObject: UIColor(inkColor), requiringSecureCoding: true), forKey: "inkColor")
    }
    var paperInkColor: UIColor {
        UIColor(presetHex: UIColor(inkColor).presetHex) ?? .black
    }
    func setInkColor(_ color: Color) {
        inkColor = Color(UIColor(presetHex: UIColor(color).presetHex) ?? .black)
        toolSettings.rememberColor(UIColor(inkColor).presetHex)
    }
    var selectedStrokePreset: Int? {
        if let index = toolSettings.selectedStrokePresets?[selectedTool.rawValue], (0..<3).contains(index) { return index }
        let width = selectedTool == .eraser ? toolSettings.eraserWidth : documentInkWidth
        let usesPattern = selectedTool == .pen || selectedTool == .fountainPen
        return toolSettings.presets(for: selectedTool).firstIndex { abs($0.width - width) < 0.001 && (!usesPattern || $0.pattern == (toolSettings.inkPattern ?? .solid)) }
    }
    func selectStrokePreset(_ index: Int) {
        guard (0..<3).contains(index) else { return }
        let preset = toolSettings.presets(for: selectedTool)[index]
        if toolSettings.selectedStrokePresets == nil { toolSettings.selectedStrokePresets = [:] }
        toolSettings.selectedStrokePresets?[selectedTool.rawValue] = index
        if selectedTool == .eraser { toolSettings.eraserWidth = preset.width }
        else {
            setDocumentInkWidth(preset.width)
            if selectedTool == .pen || selectedTool == .fountainPen { toolSettings.inkPattern = preset.pattern }
        }
    }
    var documentInkWidth: Double { inkWidth * (selectedTool == .marker ? 4 : 1) }
    var documentInkWidthRange: ClosedRange<Double> { selectedTool == .marker ? 2...128 : 0.5...32 }
    func setDocumentInkWidth(_ width: Double) {
        guard width.isFinite else { return }
        let range = documentInkWidthRange
        inkWidth = min(range.upperBound, max(range.lowerBound, width)) / (selectedTool == .marker ? 4 : 1)
    }
    var inkingType: InkInk.InkType {
        if selectedTool == .pencil { return .pencil }
        if selectedTool == .marker { return .marker }
        if selectedTool == .fountainPen || toolSettings.penStyle == .fountain { return .fountainPen }
        return toolSettings.penStyle == .ballpoint ? .monoline : .pen
    }
    var tool: InkTool {
        switch selectedTool {
        case .eraser: return InkEraserTool(toolSettings.eraserMode == .pixel ? .bitmap : .vector, width: toolSettings.eraserWidth)
        case .lasso: return InkLassoTool()
        default: return InkInkingTool(inkingType, color: paperInkColor, width: documentInkWidth)
        }
    }
    let store: LibraryStore
    let noteID: UUID
    /// This notebook's slice of the library, so the editor need not observe the whole `LibraryStore`.
    @Published private(set) var pages: [NotePage] = []
    @Published private(set) var title = "Notebook"
    @Published private(set) var storeError: String?
    var artwork: PageArtwork?
    var backgroundData: Data?
    var resources: [String: Data] = [:]
    private var opening = UUID()
    private var pending: [UUID: (NotePage, InkDrawing, UUID)] = [:]
    private var autosave: Task<Void, Never>?
    private var writeTask: Task<Bool, Never>?
    var ocrTask: Task<Void, Never>?
    init(store: LibraryStore, noteID: UUID, preferences: UserDefaults = .standard) {
        self.store = store; self.noteID = noteID; self.preferences = preferences
        if let data = preferences.data(forKey: "editorToolSettings"),
           let saved = try? JSONDecoder().decode(EditorToolSettings.self, from: data),
           saved.stabilization.isFinite, (0...100).contains(saved.stabilization),
           saved.stabilizationByStyle?.values.allSatisfy({ $0.isFinite && (0...100).contains($0) }) != false,
           saved.pressureSensitivity.map({ $0.isFinite && (0...1).contains($0) }) != false,
           saved.tipSharpness.map({ $0.isFinite && (0...1).contains($0) }) != false,
           saved.eraserWidth.isFinite, (4...100).contains(saved.eraserWidth),
           saved.toolbarFavoriteColors.map({ $0.count <= 64 && $0.allSatisfy { UIColor(presetHex: $0) != nil } }) != false,
           saved.favoriteColors.values.allSatisfy({ $0.count <= 64 && $0.allSatisfy { UIColor(presetHex: $0) != nil } }),
           saved.instrumentFavoriteColors?.values.allSatisfy({ $0.count <= 64 && $0.allSatisfy { UIColor(presetHex: $0) != nil } }) != false {
            var restored = saved
            restored.toolbarOrder = saved.normalizedToolbarOrder
            if let history = saved.colorHistory {
                var seen = Set<String>()
                restored.colorHistory = Array(history.lazy.map { $0.uppercased() }.filter { UIColor(presetHex: $0) != nil && seen.insert($0).inserted }.prefix(20))
            }
            toolSettings = restored
        } else if let legacy = preferences.string(forKey: "favoriteInkColors") {
            let colors = legacy.split(separator: ",").map(String.init).filter { UIColor(presetHex: $0) != nil }
            if !colors.isEmpty { toolSettings.favoriteColors["pen"] = Array(colors.prefix(64)) }
        }
        let saved = preferences.data(forKey: "instrumentPresets").flatMap { try? JSONDecoder().decode([DrawingToolPreset].self, from: $0) } ?? []
        let legacyWidth = preferences.object(forKey: "inkWidth") as? Double
        let legacyColor = UIColor(data: preferences.data(forKey: "inkColor"))
        instrumentPresets = DrawingToolPreset.defaults.map { original in
            if var preset = saved.first(where: { $0.kind == original.kind }), preset.width.isFinite,
               (DrawingToolPreset.minimumWidth...DrawingToolPreset.maximumWidth).contains(preset.width), UIColor(presetHex: preset.colorHex) != nil {
                if preferences.integer(forKey: "instrumentPresetUnits") != 1 && preset.kind == .marker { preset.width /= 4 }
                return preset
            }
            var preset = original
            if preset.kind == .marker { preset.width /= 4 }
            if saved.isEmpty, original.isWritingTool {
                if let legacyWidth, legacyWidth.isFinite, legacyWidth > 0 { preset.width = min(32, max(0.5, legacyWidth)) }
                if let legacyColor { preset.colorHex = legacyColor.presetHex }
            }
            return preset
        }
        preferences.set(try? JSONEncoder().encode(instrumentPresets), forKey: "instrumentPresets")
        preferences.set(1, forKey: "instrumentPresetUnits")
        selectedTool = DrawingToolKind(rawValue: preferences.string(forKey: "inkTool") ?? "pen") ?? .pen
        restoreInstrument()
        if let index = toolSettings.selectedStrokePresets?[selectedTool.rawValue] { selectStrokePreset(index) }
        canvas.tool = tool
        // Every autosave and edit rewrites the current page (revision, ink file): republishing `pages` each time
        // re-rendered the whole editor mid-gesture. Adding, removing or reordering pages shows at once; content-only
        // changes (thumbnails) follow once edits pause.
        let notebookPages = store.$library.map { $0.pages(in: noteID) }.removeDuplicates()
        notebookPages.removeDuplicates { $0.map(\.id) == $1.map(\.id) }
            .merge(with: notebookPages.debounce(for: .seconds(1.5), scheduler: RunLoop.main))
            .removeDuplicates().assign(to: &$pages)
        store.$library.map { $0.note(id: noteID)?.title ?? "Notebook" }.removeDuplicates().assign(to: &$title)
        store.$error.removeDuplicates().assign(to: &$storeError)
        store.register(self)
    }
    @Published var cloudInstalling = false
    var cloudDocumentEditorPresented = false
    var pendingDocumentActions = 0
    private var additionalCanvases: [() -> InkCanvasView?] = []
    func registerCanvas(_ canvas: InkCanvasView) {
        additionalCanvases = additionalCanvases.filter { $0() != nil && $0() !== canvas }
        additionalCanvases.append { [weak canvas] in canvas }
    }
    private var cloudCanvases: [InkCanvasView] { [canvas] + additionalCanvases.compactMap { $0() }.filter { $0 !== canvas } }
    var cloudInputViews: [UIView] {
        cloudCanvases.map { canvas in
            var parent = canvas.superview
            while let view = parent {
                if view is PageScrollView { return view }
                parent = view.superview
            }
            return canvas
        }
    }
    var cloudInteractionActive: Bool {
        busy || cloudInstalling || pendingDocumentActions > 0 || cloudDocumentEditorPresented || cloudCanvases.contains(where: \.hasActiveStroke) ||
        cloudInputViews.contains { ($0 as? PageScrollView)?.cloudInteractionActive == true }
    }
    var cloudHasUnsavedEdits: Bool { dirty || !stickyDrafts.isEmpty || !pending.isEmpty || writeTask != nil }
    func reloadFromCloud() async {
        let id = page?.id
        page = nil; cancelPreparation()
        for canvas in cloudCanvases { canvas.cancelActiveStroke(); canvas.undoManager?.removeAllActions() }
        await open(id)
        for canvas in cloudCanvases { canvas.drawing = drawing }
        canvasPageID = page?.id
    }
    private var prepared: (NotePage, Task<PreparedPage, Error>)?
    func preparePage(_ id: UUID?) {
        guard let id, let target = store.library.page(id: id), target.noteID == noteID else { cancelPreparation(); return }
        guard prepared?.0 != target else { return }
        cancelPreparation()
        let disk = store.disk
        prepared = (target, Task { try await PreparedPage.load(target, disk: disk) })
    }
    func cancelPreparation() { prepared?.1.cancel(); prepared = nil }
    func open(_ id: UUID? = nil) async {
        let request = UUID(); opening = request
        let started = ProcessInfo.processInfo.systemUptime
        let endSignpost = Perf.begin("page.open"); defer { endSignpost() }
        Diagnostics.shared.record("page.open.begin", ["request": request.uuidString, "note": noteID.uuidString, "page": id?.uuidString ?? "first"])
        defer { Diagnostics.shared.record("page.open.end", ["request": request.uuidString, "currentPage": page?.id.uuidString ?? "none", "obsolete": String(opening != request), "ms": String(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))]) }
        busy = true; defer { if opening == request { busy = false } }
        guard await flush(), opening == request else {
            if opening == request { cancelPreparation() }
            return
        }
        guard let target = id.flatMap({ store.library.page(id: $0) }).flatMap({ $0.noteID == noteID ? $0 : nil }) ?? store.library.firstPage(in: noteID) else { return }
        do {
            let reusable = page?.id == target.id && page?.backgroundID == target.backgroundID && page?.pdfIndex == target.pdfIndex ? artwork : nil
            let loaded: PreparedPage
            if let cached = prepared, cached.0 == target {
                prepared = nil
                do { loaded = try await cached.1.value }
                catch {
                    try Task.checkCancellation()
                    loaded = try await PreparedPage.load(target, disk: store.disk, reusing: reusable)
                }
            } else {
                cancelPreparation()
                loaded = try await PreparedPage.load(target, disk: store.disk, reusing: reusable)
            }
            guard opening == request, !Task.isCancelled else { return }
            // Flush strokes made while the old page was still visible.
            guard await flush(), opening == request else { return }
            backgroundData = loaded.background
            self.resources = page?.id == target.id ? self.resources.merging(loaded.resources) { _, new in new } : loaded.resources
            self.artwork = loaded.artwork
            if page?.id != target.id { searchHighlights = [] }
            drawing = page?.id == target.id ? drawing : loaded.drawing; page = store.library.page(id: target.id) ?? target
            error = nil
            UserDefaults.standard.set(noteID.uuidString, forKey: "lastNote")
            UserDefaults.standard.set(target.id.uuidString, forKey: "lastPage-\(noteID)")
        } catch { Diagnostics.shared.failure("page.open.failure", error: error); if opening == request { self.error = error.localizedDescription } }
    }
    func changed(_ drawing: InkDrawing) {
        guard let page else { return }
        self.drawing = drawing
        if !dirty { dirty = true; Diagnostics.shared.record("ink.dirty", ["page": page.id.uuidString, "strokes": String(drawing.strokes.count)]) }
        pending[page.id] = (page, drawing, UUID())
        scheduleAutosave()
    }
    /// Writes after a pause in editing, and never in the middle of a stroke, drag, scroll or zoom:
    /// a save landing mid-gesture was the main cause of dropped frames on older iPads.
    private func scheduleAutosave(after requested: UInt64? = nil) {
        let delay = requested ?? UInt64(AppPreferences.autosaveDelay * 1_000_000_000)
        autosave?.cancel()
        autosave = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard let self else { return }
            if self.interacting { self.scheduleAutosave(after: 500_000_000); return }
            _ = await self.flush()
        }
    }
    private var interacting: Bool {
        canvas.hasActiveStroke || canvas.isTracking || canvas.isDragging || canvas.isDecelerating || canvas.isZooming ||
            cloudInputViews.contains { ($0 as? PageScrollView)?.isManipulating == true }
    }
    @discardableResult func flush() async -> Bool {
        commitStickyEdits()
        guard stickyDrafts.isEmpty else { return false }
        autosave?.cancel(); autosave = nil
        if let writeTask {
            guard await writeTask.value else { return false }
            return await flush()
        }
        if pending.isEmpty {
            if dirty { store.persist() }
            let saved = await store.flush()
            if saved { dirty = false }
            return saved
        }
        let batch = pending
        let endSignpost = Perf.begin("autosave.flush"); defer { endSignpost() }
        Diagnostics.shared.record("ink.save.begin", ["pages": String(batch.count)])
        let task = Task { () -> Bool in
            defer { writeTask = nil }
            do {
                var savedResources: [UUID: String] = [:]
                for (id, item) in batch {
                    let (_, drawing, _) = item
                    let data = try await Task.detached(priority: .utility) { try Perf.measure("autosave.encode") { try drawing.encodedData() } }.value
                    savedResources[id] = try await store.disk.writeDrawingRevision(data)
                }
                var snapshot = store.library
                for (id, name) in savedResources {
                    guard let index = snapshot.pages.firstIndex(where: { $0.id == id }),
                          let noteIndex = snapshot.notes.firstIndex(where: { $0.id == snapshot.pages[index].noteID }) else { throw CocoaError(.userCancelled) }
                    snapshot.pages[index].drawingResourceID = name
                    snapshot.pages[index].drawingRevision = (snapshot.pages[index].drawingRevision ?? 0) + 1
                    snapshot.pages[index].revision = (snapshot.pages[index].revision ?? 0) + 1
                    snapshot.pages[index].modifiedAt = Date()
                    snapshot.notes[noteIndex].updatedAt = Date()
                }
                store.library = snapshot
                store.persist()
                guard await store.flush() else { throw CocoaError(.fileWriteUnknown) }
                for (id, item) in batch where pending[id]?.2 == item.2 { pending[id] = nil }
                if let id = self.page?.id { self.page = store.library.page(id: id) }
                dirty = !pending.isEmpty; Diagnostics.shared.record("ink.save.ok", ["remaining": String(pending.count)]); return true
            } catch { Diagnostics.shared.failure("editor.failure", error: error); self.error = "Unsaved handwriting: \(error.localizedDescription)"; return false }
        }
        writeTask = task
        guard await task.value else { return false }
        return pending.isEmpty ? true : await flush()
    }
    func refresh(_ updated: NotePage) async {
        pendingDocumentActions += 1; defer { pendingDocumentActions -= 1 }
        guard !isReadOnly, await flush() else { return }
        var updated = updated
        if let latest = store.library.page(id: updated.id) {
            updated.drawingRevision = latest.drawingRevision
            updated.pdfText = latest.pdfText ?? updated.pdfText
            updated.ocrText = latest.ocrText
        }
        store.updatePage(updated)
        await open(updated.id)
    }
    /// `durable: false` (direct manipulation): show the edit at once and let the autosave write it, like ink and lasso moves.
    @discardableResult func apply(_ action: DocumentAction, durable: Bool = true) async -> Bool {
        pendingDocumentActions += 1; defer { pendingDocumentActions -= 1 }
        guard !isReadOnly, action.pageID == page?.id, await prepareEdit(durable: durable) else { return false }
        do {
            guard let current = page else { return false }
            if action.kind == .setBookmark {
                try await store.apply(action)
                guard await store.flush() else { error = store.error; return false }
                page = store.library.page(id: current.id)
                return true
            }
            let updated = try action.applying(to: current)
            if updated.elements == current.elements { return true }
            for item in updated.elements ?? [] {
                if let name = item.resource, resources[name] == nil {
                    guard let bytes = try await store.disk.read(name) else { throw CocoaError(.fileNoSuchFile) }
                    resources[name] = bytes
                }
            }
            error = nil
            replaceContent(drawing, elements: updated.elements ?? [], actionName: "Edit elements", attachObjects: true)
            guard error == nil else { return false }
            return durable ? await flush() : true
        } catch { Diagnostics.shared.failure("editor.failure", error: error); self.error = error.localizedDescription; return false }
    }
    func replaceContent(_ drawing: InkDrawing, elements: [PageElement], actionName: String, attachObjects: Bool = false) {
        guard !isReadOnly, let page else { return }
        let elements = reconcileStickyElements(elements, previous: page.elements ?? [], attaching: attachObjects)
        let drawing = reconcileStickyInk(drawing, previous: page.elements ?? [], updated: elements)
        do {
            let updated = try DocumentAction(pageID: page.id, kind: .setElements, elements: elements).applying(to: page)
            guard elements.allSatisfy({ $0.kind != .image || $0.resource.flatMap { resources[$0] } != nil }) else { throw CocoaError(.fileNoSuchFile) }
            let previousDrawing = self.drawing, previousElements = page.elements ?? []
            registerContentUndo(previousDrawing, elements: previousElements, actionName: actionName)
            store.updatePage(updated)
            self.page = store.library.page(id: page.id) ?? updated
            artwork = PageArtwork(page: updated, data: backgroundData, resources: resources)
            canvas.drawing = drawing
            changed(drawing)
            refreshUndoAvailability()
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func registerContentUndo(_ drawing: InkDrawing, elements: [PageElement], actionName: String) {
        canvas.undoManager?.registerUndo(withTarget: self) { target in
            target.replaceContent(drawing, elements: elements, actionName: actionName)
        }
        canvas.undoManager?.setActionName(actionName)
    }
    func insertImage(_ image: UIImage, at position: CGPoint? = nil, centered: Bool = false) async {
        pendingDocumentActions += 1; defer { pendingDocumentActions -= 1 }
        guard !isReadOnly, await flush(), let original = page else { return }
        do {
            let (data, size) = try await Task.detached(priority: .userInitiated) { try ImportedImage.encode(image, crop: nil) }.value
            guard page?.id == original.id else { throw CocoaError(.userCancelled) }
            var item = PageElement(kind: .image)
            let pageSize = PageRenderer.size(original)
            item.width = min(pageSize.width * 0.6, 420)
            item.height = item.width * size.height / max(1, size.width)
            if item.height > pageSize.height * 0.6 { item.width *= pageSize.height * 0.6 / item.height; item.height = pageSize.height * 0.6 }
            item.x = min(max(0, position.map { $0.x - (centered ? item.width / 2 : 0) } ?? (pageSize.width - item.width) / 2), pageSize.width - item.width)
            item.y = min(max(0, position.map { $0.y - (centered ? item.height / 2 : 0) } ?? (pageSize.height - item.height) / 2), pageSize.height - item.height)
            let name = UUID().uuidString + ".png"
            try await store.disk.write(data, name: name); item.resource = name
            await apply(.init(pageID: original.id, kind: .upsertElement, element: item))
        } catch { Diagnostics.shared.failure("editor.failure", error: error); self.error = error.localizedDescription }
    }
    func paste(at point: CGPoint) async {
        pendingDocumentActions += 1; defer { pendingDocumentActions -= 1 }
        guard !isReadOnly else { return }
        Diagnostics.shared.record("paste.begin", ["types": UIPasteboard.general.types.joined(separator: ",")])
        if await pasteSelection(at: point) { Diagnostics.shared.record("paste.native"); return }
        guard await flush(), let page else { return }
        do {
            let size = PageRenderer.size(page)
            if let bytes = UIPasteboard.general.data(forPasteboardType: DocumentClipboard.inkType) {
                let pasted = try DocumentClipboard.decodeInk(bytes, at: point, pageSize: size, centered: true)
                let previous = canvas.drawing
                let merged = InkDrawing(strokes: previous.strokes + pasted.strokes)
                replaceDrawing(merged, actionName: "Paste strokes")
            } else if let image = UIPasteboard.general.image {
                await insertImage(image, at: point, centered: true)
            } else if let text = UIPasteboard.general.string, !text.isEmpty {
                guard text.count <= 100_000 else { throw CocoaError(.fileReadTooLarge) }
                var item = PageElement(kind: .text)
                item.text = text
                item.width = min(300, size.width); item.height = min(180, size.height)
                item.x = min(max(0, point.x), size.width - item.width); item.y = min(max(0, point.y), size.height - item.height)
                await apply(.init(pageID: page.id, kind: .upsertElement, element: item))
            } else { error = "The clipboard contains no compatible image, text or strokes." }
        } catch { Diagnostics.shared.failure("editor.failure", error: error); self.error = error.localizedDescription }
    }
    func recognize() {
        guard let page, let image = background?.cgImage else { return }
        ocrTask?.cancel(); busy = true
        ocrTask = Task {
            do {
                let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
                let text = try await withTaskCancellationHandler(operation: {
                    try await Task.detached(priority: .utility) {
                        try VNImageRequestHandler(cgImage: image).perform([request])
                        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                    }.value
                }, onCancel: { request.cancel() })
                try Task.checkCancellation()
                guard var updated = store.library.page(id: page.id) else { return }
                updated.recognizedText = text
                store.updatePage(updated)
                if self.page?.id == page.id { self.page = updated }
            } catch is CancellationError { }
            catch { Diagnostics.shared.failure("editor.failure", error: error); self.error = error.localizedDescription }
            busy = false
        }
    }
    func cancelOCR() { ocrTask?.cancel(); ocrTask = nil; busy = false }
}

private extension UIColor {
    convenience init?(data: Data?) {
        guard let data, let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: UIColor.self, from: data) else { return nil }
        self.init(cgColor: color.cgColor)
    }
}

@MainActor
extension EditorSession {
    func recognizeShape() {
        let drawing = canvas.drawing
        guard let last = drawing.strokes.last,
              let points = ShapeRecognition.recognize(last.path.map { $0.location.applying(last.transform) }) else {
            error = "Ambiguous stroke: draw a line, rectangle or closed ellipse."; return
        }
        let controls = points.enumerated().map { index, point in
            InkStrokePoint(location: point, timeOffset: Double(index) * 0.01, size: last.path.first?.size ?? CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let replacement = InkStroke(ink: last.ink, path: InkStrokePath(controlPoints: controls, creationDate: Date()))
        replaceDrawing(InkDrawing(strokes: Array(drawing.strokes.dropLast()) + [replacement]), actionName: "Smooth stroke")
    }
}
