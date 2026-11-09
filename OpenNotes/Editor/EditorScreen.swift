import SwiftUI
import UIKit

struct EditorScreen: View {
    @StateObject private var session: EditorSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("fingerDrawing") private var finger = false
    @AppStorage("verticalPaging") private var verticalPaging = false
    @State private var annotationsShown = false
    @State private var searchShown = false
    @State private var stickyNote: PageElement?
    @State private var textElement: PageElement?
    @State private var shapeElement: PageElement?
    @State private var selectionKind: PageElement.Kind?
    @State private var selecting = false
    @State private var capture: UIImage?
    @State private var captureShown = false
    @State private var copyConfirmation = false
    @State private var previousPreview: UIImage?
    @State private var nextPreview: UIImage?
    @State private var pageDirection = 1
    @State private var exporting = false
    @State private var editingImages = false
    @State private var imageToSelect: UUID?
    @State private var pagesShown = false
    @State private var pagePanelEditing = false
    @State private var exportShown = false
    @State private var paperShown = false
    @State private var elementsShown = false
    @State private var share: ShareFile?
    @State private var diagnosticsShown = false
    @State private var pendingShare: ShareFile?
    @State private var sharingError: String?
    @State private var deleteShown = false
    @State private var deletePageID: UUID?
    @State private var first = 1
    @State private var last = 1
    // Not observed: the session publishes this notebook's pages, title and store errors.
    let store: LibraryStore
    let noteID: UUID
    @State private var renameShown = false
    @State private var notebookTitle = ""
    init(store: LibraryStore, noteID: UUID, session: EditorSession? = nil) {
        self.store = store; self.noteID = noteID
        _session = StateObject(wrappedValue: session ?? EditorSession(store: store, noteID: noteID))
    }
    var pages: [NotePage] { session.pages }
    private var documentEditorPresented: Bool {
        stickyNote != nil || textElement != nil || shapeElement != nil || paperShown || elementsShown || annotationsShown || renameShown
    }
    private var neighboringPages: [NotePage] {
        [currentIndex - 1, currentIndex + 1].compactMap { pages.indices.contains($0) ? pages[$0] : nil }
    }
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                quickActions
                if toolbarPosition == "top", !session.isReadOnly { instrumentBar; Divider() }
                // Image placement and post-it placement need no banner: tapping the page ends or places them.
                if selecting { modeBanner }
                HStack(spacing: 0) {
                    if toolbarPosition == "left", !session.isReadOnly { instrumentBar; Divider() }
                    if pagesShown && geometry.size.width >= 700 {
                        pagePanel(closeOnSelection: false)
                            .frame(width: min(280, geometry.size.width * 0.3))
                        Divider()
                    } else if searchShown && geometry.size.width >= 700 {
                        searchPanel(closeOnSelection: false)
                            .frame(width: min(280, geometry.size.width * 0.3))
                        Divider()
                    }
                    canvasWorkspace.background(OpenNotesStyle.canvas)
                    if toolbarPosition == "right", !session.isReadOnly { Divider(); instrumentBar }
                }
                if toolbarPosition == "bottom", !session.isReadOnly { Divider(); instrumentBar }
            }
            .sheet(isPresented: Binding(get: { pagesShown && geometry.size.width < 700 }, set: { pagesShown = $0 })) { pageList }
            .sheet(isPresented: Binding(get: { searchShown && geometry.size.width < 700 }, set: { searchShown = $0 })) { searchPanel(closeOnSelection: true) }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: pagesShown)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: searchShown)
            .onChange(of: pagesShown) { if $0 { searchShown = false } }
            .onChange(of: searchShown) { if $0 { pagesShown = false } }
        }
        // The keyboard slides over the page instead of shrinking it (the page used to refit and jump).
        .ignoresSafeArea(.keyboard, edges: .bottom)
        // Bottom corner, clear of the toolbar menus; it only appears when the work lasts long enough to notice.
        .overlay(alignment: .bottomTrailing) { ActivityIndicator(store: store, loading: session.busy).allowsHitTesting(false) }
        .overlay(alignment: .bottom) {
            if copyConfirmation {
                Label("Screenshot copied", systemImage: "checkmark.circle.fill")
                    .font(.subheadline).padding(12).background(.regularMaterial, in: Capsule())
                    .padding().allowsHitTesting(false)
            }
        }
        .clipped()
        .background(Color(uiColor: .systemBackground))
        .disabled(session.cloudInstalling)
        .navigationBarBackButtonHidden().toolbar(.hidden, for: .navigationBar)
        .task(id: copyConfirmation) {
            guard copyConfirmation else { return }
            do { try await Task.sleep(nanoseconds: 4_000_000_000); copyConfirmation = false }
            catch { }
        }
        .task {
            let id = UserDefaults.standard.string(forKey: "lastPage-\(noteID)").flatMap(UUID.init(uuidString:))
            await session.open(id)
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active {
                let taskID = UIApplication.shared.beginBackgroundTask(withName: "Save notes")
                Task { await session.flush(); UIApplication.shared.endBackgroundTask(taskID) }
            }
        }
        .onAppear { session.cloudDocumentEditorPresented = documentEditorPresented }
        .onChange(of: documentEditorPresented) { session.cloudDocumentEditorPresented = $0 }
        .onDisappear { session.cloudDocumentEditorPresented = false; session.stickyInsertionColor = nil; finishMode(); session.cancelPreparation(); session.cancelOCR(); Task { await session.flush() } }
        .onChange(of: session.page?.id) { _ in session.stickyInsertionColor = nil; finishMode() }
        .task(id: neighboringPages) {
            previousPreview = nil; nextPreview = nil
            let index = currentIndex; let ordered = pages
            do {
                if ordered.indices.contains(index - 1) { let image = try await store.disk.thumbnail(ordered[index - 1], pixels: AppPreferences.batterySaver ? 800 : 1400); try Task.checkCancellation(); previousPreview = image }
                try Task.checkCancellation()
                if ordered.indices.contains(index + 1) { let image = try await store.disk.thumbnail(ordered[index + 1], pixels: AppPreferences.batterySaver ? 800 : 1400); try Task.checkCancellation(); nextPreview = image }
            } catch { }
        }
        .alert("Rename notebook", isPresented: $renameShown) {
            TextField("Title", text: $notebookTitle)
            Button("Save") {
                let title = notebookTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                store.update(noteID) { $0.title = title.isEmpty ? "Untitled" : title }
            }
            Button("Cancel", role: .cancel) { }
        }
        .sheet(isPresented: $annotationsShown) { AnnotationsSheet(session: session) { item in
            Task { try? await Task.sleep(nanoseconds: 300_000_000); stickyNote = item }
        } }
        .sheet(item: $stickyNote) { StickyNoteSheet(session: session, note: $0) }
        .sheet(item: $textElement, onDismiss: { session.selectedTool = .lasso }) { item in
            if let page = session.page { TextElementSheet(session: session, pageID: page.id, element: item) }
        }
        .sheet(item: $shapeElement, onDismiss: { session.selectedTool = .lasso }) { item in
            if let page = session.page { ShapeElementSheet(session: session, pageID: page.id, element: item) }
        }
        .sheet(isPresented: $captureShown) { [capture] in if let capture { CaptureSheet(image: capture) { beginImagePlacement(); Task { await session.insertImage(capture) } } } }
        .sheet(isPresented: $paperShown) { PaperSheet(session: session) }
        .sheet(isPresented: $elementsShown, onDismiss: { finishMode(); session.selectedTool = .lasso; editingImages = session.page?.elements?.contains(where: { $0.kind == .image }) == true }) { ElementSheet(session: session) }
        .sheet(isPresented: $exportShown, onDismiss: {
            if let pendingShare { share = pendingShare; self.pendingShare = nil }
        }) { exportForm }
        .sheet(item: $share, onDismiss: {
            if let sharingError { session.error = sharingError; self.sharingError = nil }
        }) { file in
            ActivitySheet(url: file.url) { error in
                sharingError = "Sharing failed: \(error.localizedDescription)"
                share = nil
            }
        }
        .alert("OpenNotes", isPresented: Binding(get: { session.error != nil || session.storeError != nil }, set: { if !$0 { session.error = nil; store.error = nil } })) {
            Button("Retry saving") { store.persist(); Task { await session.flush() } }
            Button("Close", role: .cancel) { session.error = nil; store.error = nil }
        } message: { Text(session.error ?? session.storeError ?? "") }
    }
    private func insertSticky() {
        guard !session.isReadOnly else { return }
        finishMode(); session.stickyInsertionColor = session.toolSettings.stickyColorHex ?? "#FFE66D"
        UIAccessibility.post(notification: .announcement, argument: "Tap the page to place a sticky note")
    }
    private func capturePage(copy: Bool = false) {
        guard let page = session.pageIncludingDrafts else { return }
        let data = session.backgroundData, drawing = session.drawing, resources = session.resources
        Task {
            do {
                let image = try await Task.detached(priority: .userInitiated) {
                    try PageRenderer.capture(page, data: data, drawing: drawing, resources: resources, rect: CGRect(origin: .zero, size: PageRenderer.size(page)), path: nil)
                }.value
                if copy { confirmImageCopy(image) }
                else { capture = image; captureShown = true }
            } catch { session.error = error.localizedDescription }
        }
    }
    private func confirmImageCopy(_ image: UIImage) {
        UIPasteboard.general.image = image
        UIAccessibility.post(notification: .announcement, argument: "Screenshot copied")
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        copyConfirmation = true
    }
    private var canvasWorkspace: some View {
        Group {
            if session.page != nil {
                WritingCanvas(session: session, finger: finger, reading: session.isReadOnly, verticalPaging: verticalPaging, editingImages: editingImages, imageToSelect: imageToSelect, pageDirection: pageDirection,
                    previousPreview: previousPreview, nextPreview: nextPreview,
                    hasPrevious: currentIndex > 0, hasNext: currentIndex + 1 < pages.count,
                    selectionMode: selecting, immediateSelection: selectionKind != nil, selectedRect: selectRegion, pasted: { finishMode() }, editNote: { stickyNote = $0 },
                    editImage: { id in beginImagePlacement(); imageToSelect = id }, imageEditingEnded: { finishMode() }, selectionMoved: { path, delta in
                        await session.moveSelection(inside: path, by: delta, durable: false)
                    }, prepare: { delta in
                        if delta == 0 { session.cancelPreparation(); return }
                        let index = currentIndex + delta
                        session.preparePage(pages.indices.contains(index) ? pages[index].id : nil)
                    }, addPage: { await quickAddPage(before: $0 < 0) }, navigate: navigate)
            } else {
                VStack { Spacer(); ProgressView("Loading page…"); Spacer() }.frame(maxWidth: .infinity)
            }
        }
    }
    @AppStorage(WritingInstrumentBar.positionKey) private var toolbarPosition = "top"
    private var instrumentBar: some View { WritingInstrumentBar(session: session, sticky: insertSticky) }
    private var quickActions: some View {
        HStack(spacing: 4) {
            Button { pagesShown.toggle(); Task { await session.flush() } } label: {
                HStack(spacing: 6) { Image(systemName: "sidebar.left"); Text("\(currentIndex + 1)/\(pages.count)").font(.caption).monospacedDigit() }
            }
            .accessibilityLabel("Pages, page \(currentIndex + 1) of \(pages.count)")
            .accessibilityIdentifier("editor.pages")
            .accessibilityValue("Page \(currentIndex + 1) of \(pages.count)")
            .accessibilityAddTraits(pagesShown ? .isSelected : [])
            Button { searchShown.toggle() } label: { Label("Search", systemImage: "magnifyingglass") }
                .accessibilityIdentifier("editor.search")
                .accessibilityAddTraits(searchShown ? .isSelected : [])
            Button {
                Task {
                    guard await session.flush() else { return }
                    finishMode(); session.stickyInsertionColor = nil; session.isReadOnly.toggle()
                }
            } label: { Label(session.isReadOnly ? "Enable editing" : "Read only", systemImage: session.isReadOnly ? "lock.fill" : "pencil.line") }
                .accessibilityIdentifier("editor.readOnly").accessibilityAddTraits(session.isReadOnly ? .isSelected : [])
            Spacer(minLength: 0)   // the notebook's name is already on its tab
            Button { Task { await quickAddPage() } } label: {
                Label("Add page", systemImage: "doc.badge.plus")
            }.disabled(session.busy || session.isReadOnly).accessibilityIdentifier("editor.addPage")
            Button { first = 1; last = pages.count; exportShown = true } label: { Label("Share and export", systemImage: "square.and.arrow.up") }.accessibilityIdentifier("editor.export")
            actionsMenu
        }.labelStyle(.iconOnly).dynamicTypeSize(...DynamicTypeSize.xxxLarge).buttonStyle(ToolButtonStyle()).padding(.horizontal, 8)
            .background(Color(uiColor: .systemBackground))
            .overlay(alignment: .bottom) { Divider() }
    }
    private var modeBanner: some View {
        ViewThatFits(in: .horizontal) {
            if !typeSize.isAccessibilitySize {
                HStack(spacing: 12) {
                    modeDescription.fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 12)
                    modeDone
                }
            }
            VStack(alignment: .leading, spacing: 8) { modeDescription; modeDone }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(uiColor: .tertiarySystemBackground))
        .overlay(alignment: .bottom) { Divider() }
    }
    private var modeDescription: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(modeTitle, systemImage: selecting ? "viewfinder" : "arrow.up.left.and.arrow.down.right").font(.subheadline.bold())
            Text(selecting ? "Outline an area on the page." : "Move or resize the image.").font(.footnote).foregroundStyle(.secondary)
        }
    }
    private var modeTitle: String {
        guard selecting else { return "Image placement" }
        switch selectionKind {
        case .highlight: return "Highlight an area"
        case .rectangle: return "Outline an area"
        default: return "Capture an area"
        }
    }
    private var modeDone: some View {
        Button { finishMode() } label: { Text(selecting ? "Cancel" : "Finish").frame(minWidth: 44, minHeight: 44) }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("editor.mode.done")
    }
    private func finishMode() {
        selecting = false; selectionKind = nil; editingImages = false; imageToSelect = nil
    }
    private func beginImagePlacement() {
        finishMode()
        session.selectedTool = .lasso
        editingImages = true
    }
    private var actionsMenu: some View {
        Menu {
            Button("Rename notebook", systemImage: "pencil") {
                notebookTitle = store.library.note(id: noteID)?.title ?? ""
                renameShown = true
            }
            Button("Search notebook", systemImage: "magnifyingglass") { searchShown = true }
            Button("Quick Screenshot & Copy", systemImage: "doc.on.clipboard") { capturePage(copy: true) }
                .disabled(session.page == nil).accessibilityIdentifier("editor.quickScreenshotCopy")
            if !session.searchHighlights.isEmpty {
                Button("Clear search results") { session.searchHighlights = [] }
            }
            if let page = session.page, page.backgroundID == nil {
                Picker(selection: Binding(get: { page.template }, set: { setTemplate($0) })) {
                    ForEach(PageTemplate.allCases) { Text($0.title).tag($0) }
                } label: { Label("Page style", systemImage: "squareshape.split.3x3") }
                    .pickerStyle(.menu).disabled(session.isReadOnly).accessibilityIdentifier("editor.pageStyle")
            }
            Button("Change paper", systemImage: "doc") { paperShown = true }.disabled(session.isReadOnly)
            Button("Image", systemImage: "photo") { elementsShown = true }.disabled(session.isReadOnly)
            Button("Text box", systemImage: "textformat") { textElement = PageElement(kind: .text, text: "") }.disabled(session.isReadOnly)
            Button("Shape", systemImage: "square.on.circle") { shapeElement = PageElement(kind: .rectangle) }.disabled(session.isReadOnly)
            Button("Capture an area", systemImage: "viewfinder") { finishMode(); selecting = true }.disabled(session.isReadOnly)
            Button("Capture entire page", systemImage: "camera") { capturePage() }
            Button("Share current page", systemImage: "square.and.arrow.up") {
                first = currentIndex + 1; last = first; exportShown = true
            }.accessibilityIdentifier("editor.sharePage")
            Button("Export notebook", systemImage: "square.and.arrow.up") {
                first = 1; last = pages.count; exportShown = true
            }.accessibilityIdentifier("editor.share")
            Divider()
            Button("Diagnostics & logs", systemImage: "stethoscope") { diagnosticsShown = true }
            Toggle("Write with your finger", isOn: $finger)
            Toggle("Ruler", isOn: Binding(get: { session.toolSettings.rulerEnabled == true }, set: { session.toolSettings.rulerEnabled = $0 }))
            Toggle("Recognize shapes", isOn: $session.toolSettings.shapeRecognitionEnabled)
            // Older notebooks may contain attachments; keep them editable.
            if session.page?.elements?.isEmpty == false {
                Button("Page attachments", systemImage: "paperclip") { elementsShown = true }.disabled(session.isReadOnly)
                Button("Page annotations", systemImage: "note.text") { annotationsShown = true }.disabled(session.isReadOnly)
                ForEach((session.page?.elements ?? []).filter { $0.kind == .text }) { item in
                    Button("Edit text: \(item.text.prefix(40))") { textElement = item }.disabled(session.isReadOnly)
                }
                ForEach((session.page?.elements ?? []).filter { ShapeElementSheet.kinds.contains($0.kind) }) { item in
                    Button("Edit \(ShapeElementSheet.title(item.kind))") { shapeElement = item }.disabled(session.isReadOnly)
                }
            }
        } label: {
            // Menu ignores ButtonStyle on iPadOS 16, so give the glyph its own 44pt hit area.
            Label("Notebook actions", systemImage: "ellipsis").labelStyle(.iconOnly)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
            .accessibilityIdentifier("editor.actions")
            .sheet(isPresented: $diagnosticsShown) { DiagnosticsScreen() }
    }
    // ponytail: current page only; new pages inherit it via quickAddPage. Add "apply to all" if asked.
    private func setTemplate(_ template: PageTemplate) {
        guard !session.isReadOnly, var page = session.page, page.template != template else { return }
        page.template = template; page.pdfIndex = nil
        Task { await session.refresh(page); _ = await store.flush() }
    }
    @discardableResult private func quickAddPage(before: Bool = false) async -> Bool {
        guard !session.isReadOnly, !session.busy, await session.flush(), let current = session.page,
              let id = await store.addPage(noteID: noteID, after: current.id) else { return false }
        // A page after a normal page continues its paper; after a PDF or image page it keeps the default style the store applied.
        if current.backgroundID == nil, var page = store.library.page(id: id) {
            page.width = current.width; page.height = current.height; page.template = current.template
            store.updatePage(page)
        }
        if before { store.movePage(id, index: currentIndex) }
        pageDirection = before ? -1 : 1; await session.open(id)
        return session.page?.id == id
    }
    private func selectRegion(_ rect: CGRect, _ path: UIBezierPath, _ action: PageSelectionAction) {
        guard !session.isReadOnly, let page = session.pageIncludingDrafts else { return }
        if action == .enlarge || action == .shrink || action == .deleteContent {
            Task {
                if await session.transformSelection(inside: path, scale: action == .enlarge ? 1.1 : 0.9, deleting: action == .deleteContent) { finishMode() }
            }
            return
        }
        if action == .copyInk {
            guard session.toolSettings.includeHandwriting else { session.error = "Enable handwriting in the lasso filters to copy strokes."; return }
            do { try DocumentClipboard.copyInk(DocumentClipboard.selectedInk(session.drawing, inside: path)); finishMode() }
            catch { session.error = "No strokes to copy in this area, or the selection is too large." }
            return
        }
        if let selectionKind {
            finishMode()
            var item = PageElement(kind: selectionKind)
            item.x = rect.minX; item.y = rect.minY; item.width = rect.width; item.height = rect.height
            Task { await session.apply(.init(pageID: page.id, kind: .upsertElement, element: item)) }
        } else {
            let drawing = session.drawing; let data = session.backgroundData; let resources = session.resources
            Task {
                do {
                    let image = try await Task.detached(priority: .userInitiated) { try PageRenderer.capture(page, data: data, drawing: drawing, resources: resources, rect: rect, path: nil) }.value
                    finishMode()
                    if action == .copyPhoto { confirmImageCopy(image) }
                    else { capture = image; captureShown = true }
                } catch { session.error = error.localizedDescription }
            }
        }
    }
    var currentIndex: Int { pages.firstIndex(where: { $0.id == session.page?.id }) ?? 0 }
    func navigate(_ delta: Int) async -> Bool {
        let index = currentIndex + delta
        guard pages.indices.contains(index), !session.busy else { return false }
        pageDirection = delta
        let id = pages[index].id
        await session.open(id)
        return session.page?.id == id
    }
    var pageList: some View { pagePanel(closeOnSelection: true) }
    private func searchPanel(closeOnSelection: Bool) -> some View {
        DocumentSearchPanel(session: session, store: store, closeOnSelection: closeOnSelection) { searchShown = false }
    }
    private func pagePanel(closeOnSelection: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text("Pages").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                Button { pagePanelEditing.toggle() } label: {
                    Label("Reorder pages", systemImage: "arrow.up.arrow.down").labelStyle(.iconOnly).frame(width: 44, height: 44)
                }.accessibilityAddTraits(pagePanelEditing ? .isSelected : []).disabled(session.isReadOnly)
                Button { pagesShown = false } label: {
                    Label("Close previews", systemImage: "xmark").labelStyle(.iconOnly).frame(width: 44, height: 44)
                }.accessibilityIdentifier("editor.pages.close")
            }.padding(.horizontal, 8).padding(.vertical, 4).background(Color(uiColor: .secondarySystemBackground))
            Divider()
            List {
                ForEach(pages) { page in
                    HStack(spacing: 12) {
                        Button { Task { await session.open(page.id); if closeOnSelection && session.page?.id == page.id { pagesShown = false } } } label: {
                            HStack(spacing: 14) {
                                PageThumbnail(page: page, disk: store.disk).frame(width: 48, height: 64)
                                    .accessibilityHidden(true)
                                Text("Page \(page.index + 1)").foregroundStyle(.primary)
                                if page.bookmark == true { Image(systemName: "bookmark.fill").accessibilityLabel("Bookmark") }
                                Spacer()
                                if page.id == session.page?.id { Image(systemName: "checkmark.circle.fill").accessibilityLabel("Current page") }
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Menu { pageActions(page) } label: {
                            Label("Page actions", systemImage: "ellipsis").labelStyle(.iconOnly).frame(width: 44, height: 44)
                        }.accessibilityLabel("Actions for page \(page.index + 1)").disabled(session.isReadOnly)
                    }.padding(.vertical, 4).contextMenu { pageActions(page) }
                }
                .onMove { offsets, destination in
                    guard !session.isReadOnly, let source = offsets.first else { return }
                    store.movePage(pages[source].id, index: destination > source ? destination - 1 : destination)
                }
            }.listStyle(.plain)
                .environment(\.editMode, .constant(pagePanelEditing ? .active : .inactive))
                .confirmationDialog("Delete this page?", isPresented: $deleteShown, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) { Task { if !session.isReadOnly, await session.flush(), let target = deletePageID, let id = store.removePage(target) { await session.open(id) } } }
                }
        }
    }
    @ViewBuilder private func pageActions(_ page: NotePage) -> some View {
        Button("Duplicate page", systemImage: "plus.square.on.square") {
            Task { if !session.isReadOnly, await session.flush(), let id = await store.addPage(noteID: noteID, after: page.id, duplicate: true) { await session.open(id) } }
        }.disabled(session.isReadOnly)
        Button("Delete page", systemImage: "trash", role: .destructive) { deletePageID = page.id; deleteShown = true }
            .disabled(pages.count < 2 || session.isReadOnly)
    }
    var exportForm: some View {
        NavigationStack {
            Form {
                if exporting { ProgressView("Export in progress…") }
                if let message = session.error ?? session.storeError {
                    Text(message).foregroundStyle(.red).accessibilityIdentifier("editor.exportError")
                }
                Stepper("From page \(first)", value: $first, in: 1...max(1, pages.count))
                Stepper("To page \(last)", value: $last, in: first...max(first, pages.count))
                Button("Export annotated PDF") { Task { await export(native: false) } }.disabled(exporting)
                Button("Back up native notebook (.catnote)") { Task { await export(native: true) } }.disabled(exporting)
                Text("Sharing lets you save to Files and its configured providers.").font(.caption)
            }.navigationTitle("Export").toolbar { Button("Cancel") { exportShown = false }.disabled(exporting) }
        }
        .interactiveDismissDisabled(exporting)
    }
    func export(native: Bool) async {
        Diagnostics.shared.record("document.export.begin", ["native": String(native)])
        guard !exporting else { return }
        exporting = true; defer { exporting = false }
        guard await session.flush() else { return }
        do {
            let selectedRange = (first - 1)...(max(first, last) - 1)
            let archive = try await store.archive(noteID, indices: native ? nil : selectedRange)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + (native ? ".catnote" : ".pdf"))
            let range = 0...(archive.pages.count - 1)
            try await Task.detached(priority: .userInitiated) {
                if native { try JSONEncoder().encode(archive).write(to: url, options: .atomic) }
                else { try PageRenderer.export(archive, indices: range, output: url) }
            }.value
            pendingShare = ShareFile(url: url)
            exportShown = false
        } catch { session.error = error.localizedDescription }
    }

}

struct ShareFile: Identifiable { let id = UUID(); let url: URL }
struct ActivitySheet: UIViewControllerRepresentable {
    let url: URL
    var onError: ((Error) -> Void)?
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, error in if let error { onError?(error) } }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}
struct PageThumbnail: View {
    let page: NotePage
    let disk: DiskStore
    @State private var image: UIImage?
    var body: some View {
        Group { if let image { Image(uiImage: image).resizable().scaledToFit() } else { Rectangle().fill(.quaternary) } }
            .aspectRatio(PageRenderer.size(page), contentMode: .fit)
            .background(.white).clipShape(RoundedRectangle(cornerRadius: 4))
            .shadow(color: .black.opacity(0.12), radius: 3, y: 2)
            .task(id: page) {
                do { image = try await disk.thumbnail(page, pixels: 640) }
                catch { image = nil }
            }
    }
}

private struct ToolButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            .background(configuration.isPressed ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .opacity(isEnabled ? 1 : 0.35)
    }
}

/// A small, late-appearing status pill: quick saves and page loads never flash it.
private struct ActivityIndicator: View {
    @ObservedObject var store: LibraryStore
    let loading: Bool
    @State private var shown = false
    private var label: String? { store.saving ? "Saving" : loading ? "Loading" : nil }
    var body: some View {
        Group {
            if shown, let label {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(label).font(.caption2) }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.thinMaterial, in: Capsule())
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .accessibilityElement(children: .combine)
            }
        }
        .task(id: label) {
            guard label != nil else { shown = false; return }
            try? await Task.sleep(nanoseconds: 400_000_000)
            if !Task.isCancelled { shown = true }
        }
    }
}
