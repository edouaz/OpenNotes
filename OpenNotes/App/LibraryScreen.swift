import SwiftUI
import UniformTypeIdentifiers

struct LibraryScreen: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var workspace: NotebookWorkspace?
    @Environment(\.scenePhase) private var scenePhase
    @State private var consumingInbox = false
    @State private var failedSharedImport: URL?
    @State private var lastOpening: Task<Void, Never>?
    @State private var path: [UUID] = []
    @State private var query = ""
    @State private var newNotebookShown = false
    @State private var accountShown = false
    @State private var diagnosticsShown = false
    @State private var selectingNotes = false
    @State private var selectedNotes: Set<UUID> = []
    @AppStorage("libraryLayout") private var layout = "grid"
    @AppStorage("appearance") private var appearance = "system"
    @State private var filter = 0
    private var trash: Bool { filter == 2 }
    private var favorites: Bool { filter == 1 }
    @State private var importer = false
    @State private var selectedFolderID: UUID?
    @State private var folderEditorShown = false
    @State private var renamedFolder: NotebookFolder?
    @State private var moveShown = false
    @State private var movingFolder: UUID?
    @State private var movingDocuments: [UUID] = []
    @AppStorage("librarySort") private var sort = "date"
    private var currentFolderID: UUID? { selectedFolderID ?? store.library.folders.first?.id }
    private var folders: [NotebookFolder] {
        guard filter == 0, query.isEmpty else { return [] }
        let children = store.library.childFolders(of: currentFolderID)
        // Safety net: a root folder created by another device is never nested under this device's home; show it here so its notebooks stay reachable.
        guard selectedFolderID == nil, let home = store.library.folders.first?.id else { return children }
        return children + store.library.rootFolders.filter { $0.id != home && !children.contains($0) }
    }
    @State private var rename: NoteDocument?
    @State private var title = ""
    @State private var deletion: [UUID] = []
    @State private var deleteShown = false
    @State private var folderDeletion: NotebookFolder?
    @State private var emptyTrashShown = false
    var notes: [NoteDocument] {
        let found = store.matchingNotes(query, trash: trash, favorites: favorites).filter {
            filter != 0 || !query.isEmpty || $0.folderID == currentFolderID
        }
        if sort == "name" { return found.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } }
        return found
    }
    var body: some View {
        NavigationStack(path: $path) {
            presentedLibrary
        }.preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
    }
    private var navigationContent: some View {
        HStack(spacing: 0) {
            if sizeClass == .regular { libraryRail.frame(width: 206); Divider() }
            libraryContent
        }
        .safeAreaInset(edge: .bottom, alignment: .leading, spacing: 0) {
            if sizeClass != .regular {
                CloudStatusLine(cloud: store.cloud) { accountShown = true }
                    .disabled(!store.ready)
                    .padding(.horizontal, 16)
                    .background(Color(uiColor: .systemGroupedBackground))
            }
        }
        .navigationTitle(trash ? "Trash" : favorites ? "Favorites" : selectedFolderID.flatMap { id in store.library.folders.first(where: { $0.id == id })?.name } ?? "Notebooks")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search notebooks")
        .onChange(of: filter) { value in if value != 0 { selectedFolderID = nil } }
        .onChange(of: notes.map(\.id)) { ids in selectedNotes.formIntersection(ids) }
        .task(id: query) {
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            for note in store.library.notes where note.deletedAt == nil {
                guard !Task.isCancelled else { return }
                await store.indexPDFText(in: note.id)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { accountShown = true } label: {
                    Label("Account and connections", systemImage: "person.crop.circle")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityIdentifier("library.account")
                .disabled(!store.ready)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if trash {
                        Button("Empty Trash", systemImage: "trash", role: .destructive) { emptyTrashShown = true }
                            .disabled(store.matchingNotes("", trash: true).isEmpty)
                    }
                    Button("Import", systemImage: "square.and.arrow.down") { importer = true }
                    Button("Diagnostics & logs", systemImage: "stethoscope") { diagnosticsShown = true }
                    Button("New notebook", systemImage: "plus") { newNotebookShown = true }
                    Button("New folder", systemImage: "folder.badge.plus") { renamedFolder = nil; folderEditorShown = true }
                    Picker("Show", selection: $filter) {
                        Text("Notebooks").tag(0)
                        Text("Favorites").tag(1)
                        Text("Trash").tag(2)
                    }
                    Picker("Layout", selection: $layout) {
                        Text("Grid").tag("grid")
                        Text("List").tag("list")
                    }
                    Picker("Appearance", selection: $appearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    Picker("Sort", selection: $sort) {
                        Text("Recently edited").tag("date")
                        Text("Name").tag("name")
                    }
                } label: { Label("Library options", systemImage: "ellipsis") }
                .accessibilityIdentifier("library.options")
                .disabled(!store.ready)
            }
        }
        .navigationDestination(for: UUID.self) { id in
            if let workspace { NotebookWorkspaceView(workspace: workspace) }
        }
    }
    private var activeLibrary: some View {
        navigationContent
            .task {
                if !store.ready { await store.load() }
                guard store.ready else { return }
                if workspace == nil {
                    let model = NotebookWorkspace(store: store)
                    workspace = model
                    await model.restore()
                    if let id = model.active { path = [id] }
                }
                await consumeInbox()
            }
            .onChange(of: scenePhase) { phase in if phase == .active { Task { await consumeInbox() } } }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in Task { await store.disk.clearThumbnails() } }
            .onOpenURL { url in Task { if let id = await store.importFile(url, folderID: currentFolderID) { openNotebook(id) } } }
            .fileImporter(isPresented: $importer, allowedContentTypes: [.pdf, .image, UTType(filenameExtension: "catnote") ?? .data]) { result in
                Task {
                    do { if let id = await store.importFile(try result.get(), folderID: currentFolderID) { openNotebook(id) } }
                    catch { store.error = error.localizedDescription }
                }
            }
    }
    private var presentedLibrary: some View {
        activeLibrary
            .alert("Rename notebook", isPresented: Binding(get: { rename != nil }, set: { if !$0 { rename = nil } })) {
                TextField("Title", text: $title)
                Button("Save") {
                    if let note = rename { store.update(note.id) { $0.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : title } }; rename = nil
                }
                Button("Cancel", role: .cancel) { rename = nil }
            }
            .alert(deletion.count == 1 ? "Move this notebook to Trash?" : "Move \(deletion.count) notebooks to Trash?", isPresented: $deleteShown, presenting: deletion) { ids in
                Button("Move to Trash", role: .destructive) {
                    for id in ids { store.update(id) { $0.deletedAt = Date() } }
                    deletion = []; selectedNotes = []; selectingNotes = false
                }
                Button("Cancel", role: .cancel) { deletion = [] }
            } message: { _ in Text("You can restore notebooks from Trash.") }
            .alert("Delete this folder and its contents?", isPresented: Binding(get: { folderDeletion != nil }, set: { if !$0 { folderDeletion = nil } })) {
                Button("Move to Trash", role: .destructive) {
                    if let folderDeletion { store.trashFolder(folderDeletion.id) }
                    folderDeletion = nil
                }
                Button("Cancel", role: .cancel) { folderDeletion = nil }
            } message: { Text("The folder and all subfolders will be removed. Their notebooks can be restored from Trash.") }
            .alert("Empty Trash?", isPresented: $emptyTrashShown) {
                Button("Empty Trash", role: .destructive) { store.emptyTrash() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("All notebooks in Trash will be removed from the library on synchronized devices. Cloud revision history is retained.") }
            .alert("OpenNotes", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
                Button("OK") { store.error = nil }
                if let failedSharedImport {
                    Button("Retry import") { Task { await consumeInbox() } }
                    Button("Remove this import", role: .destructive) {
                        do { try ShareInbox.remove(failedSharedImport); self.failedSharedImport = nil; Task { await consumeInbox() } }
                        catch { store.error = error.localizedDescription }
                    }
                }
                if !store.ready { Button("Restore backup copy") { Task { await store.restore() } } }
            } message: { Text(store.error ?? "") }
            .sheet(isPresented: $newNotebookShown) {
                NewNotebookSheet(store: store, folderID: currentFolderID, created: openNotebook)
            }
            .sheet(isPresented: $diagnosticsShown) { DiagnosticsScreen() }
            .sheet(isPresented: $accountShown) {
                CloudScreen(store: store)
            }
            .sheet(isPresented: $folderEditorShown) {
                FolderNameSheet(name: renamedFolder?.name ?? "", title: renamedFolder == nil ? "New folder" : "Rename folder") { name in
                    let action = LibraryAction(kind: renamedFolder == nil ? .createFolder : .renameFolder, folderID: renamedFolder?.id, parentID: currentFolderID, name: name)
                    return store.apply(action) != nil
                }
            }
            .sheet(isPresented: $moveShown) {
                FolderPickerSheet(store: store, movingFolderID: movingFolder) { destination in
                    if let movingFolder { store.apply(.init(kind: .moveFolder, folderID: movingFolder, parentID: destination)) }
                    else { store.apply(.init(kind: .moveDocuments, folderID: destination, documentIDs: movingDocuments)) }
                }
            }
    }
    private var libraryContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                libraryHeader
                if !trash { libraryControls }
                if selectingNotes && !selectedNotes.isEmpty && !trash {
                    HStack {
                        Text("\(selectedNotes.count) selected").font(.subheadline)
                        Spacer()
                        Button("Move to…", systemImage: "folder") {
                            movingFolder = nil; movingDocuments = Array(selectedNotes); moveShown = true
                            selectingNotes = false; selectedNotes = []
                        }.accessibilityIdentifier("library.move")
                        .frame(minHeight: 44)
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            deletion = Array(selectedNotes); deleteShown = true
                        }.accessibilityIdentifier("library.delete")
                        .frame(minWidth: 44, minHeight: 44)
                    }.padding(12).background(OpenNotesStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
                if filter == 0 && query.isEmpty && selectedFolderID != nil { folderBreadcrumbs }
                if !store.ready { ProgressView("Opening library…") }
                else if notes.isEmpty && folders.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: !query.isEmpty ? "magnifyingglass" : trash ? "trash" : "book.closed").font(.largeTitle).foregroundStyle(OpenNotesStyle.accent).accessibilityHidden(true)
                        Text(!query.isEmpty ? "No results" : trash ? "Trash is empty" : favorites ? "Your favorite notebooks" : "A page for your ideas").font(.title2.weight(.semibold))
                        Text(!query.isEmpty ? "No notebooks match “\(query)”." : trash ? "Deleted notebooks appear here." : favorites ? "Star a notebook to find it here." : "Create your first notebook or import a document to start writing.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                        if !query.isEmpty { Button("Clear search") { query = "" }.frame(minHeight: 44) }
                    }.frame(maxWidth: .infinity).padding(.vertical, 56)
                }
                if layout == "list" {
                    LazyVStack(spacing: 8) {
                        ForEach(folders) { folder in folderRow(folder) }
                        ForEach(notes) { note in noteRow(note) }
                    }.accessibilityIdentifier("library.list")
                } else {
                    LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 174, maximum: 245), spacing: 20)], alignment: .leading, spacing: 24) {
                        ForEach(folders) { folder in folderCard(folder) }
                        ForEach(notes) { note in noteCard(note) }
                    }.accessibilityIdentifier("library.grid")
                }
            }.padding(dynamicTypeSize.isAccessibilitySize || sizeClass != .regular ? 16 : 28)
        }.frame(maxWidth: .infinity).background(Color(uiColor: .systemGroupedBackground))
    }
    private var libraryHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(trash ? "Trash" : favorites ? "Favorites" : selectedFolderID.flatMap { id in store.library.folders.first { $0.id == id }?.name } ?? "Your notebooks")
                .font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            Text(trash ? "Restore notebooks whenever you need them." : "\(notes.count) notebooks · All your ideas, together.")
                .font(.subheadline).foregroundStyle(.secondary)
        }.padding(.top, 8)
    }
    private var libraryControls: some View {
        ViewThatFits {
            HStack(spacing: 12) { newNoteButton; Spacer(); libraryViewControls }
            VStack(alignment: .leading, spacing: 12) { newNoteButton; libraryViewControls }
        }
    }
    private var libraryViewControls: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Documents") { filter = 0 }
                Button("Favorites") { filter = 1 }
                Button("Trash") { filter = 2 }
            } label: { Label("Show", systemImage: "line.3.horizontal.decrease").fixedSize() }.accessibilityIdentifier("library.filter")
            Button(selectingNotes ? "Done" : "Select") { selectingNotes.toggle(); selectedNotes = [] }.accessibilityIdentifier("library.select")
            Picker("Library layout", selection: $layout) {
                Image(systemName: "square.grid.2x2").tag("grid")
                Image(systemName: "list.bullet").tag("list")
            }.pickerStyle(.segmented).frame(width: 100).accessibilityIdentifier("library.layout")
        }.frame(minHeight: 44)
    }
    private var libraryRail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("OpenNotes", systemImage: "book.closed.fill").font(.title2.bold()).padding(.vertical, 24)
            ForEach(Array(["Documents", "Favorites", "Trash"].enumerated()), id: \.offset) { index, name in
                Button { filter = index; selectedFolderID = nil } label: {
                    Label(name, systemImage: ["square.grid.2x2", "star", "trash"][index])
                        .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).padding(.horizontal, 12)
                        .foregroundStyle(filter == index ? OpenNotesStyle.accent : .secondary)
                        .background(filter == index ? OpenNotesStyle.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).accessibilityAddTraits(filter == index ? .isSelected : [])
            }
            Divider().padding(.vertical, 12)
            Button { importer = true } label: { Label("Import document", systemImage: "square.and.arrow.down").frame(minHeight: 44) }
            Button { renamedFolder = nil; folderEditorShown = true } label: { Label("New folder", systemImage: "folder.badge.plus").frame(minHeight: 44) }
            Spacer()
            CloudStatusLine(cloud: store.cloud) { accountShown = true }
                .disabled(!store.ready).padding(.bottom, 20)
        }.padding(.horizontal, 18).background(OpenNotesStyle.rail)
    }
    private func toggleSelection(_ id: UUID) {
        if selectedNotes.contains(id) { selectedNotes.remove(id) } else { selectedNotes.insert(id) }
    }
    private func folderRow(_ folder: NotebookFolder) -> some View {
        HStack {
            Button { selectedFolderID = folder.id } label: {
                Label(folder.name, systemImage: "folder.fill").frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            }.buttonStyle(.plain).accessibilityIdentifier("library.folder.\(folder.id.uuidString)")
            Menu { folderActions(folder) } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("Actions for \(folder.name)")
        }.padding(.horizontal, 14).background(OpenNotesStyle.chrome, in: RoundedRectangle(cornerRadius: 12))
    }
    private func noteRow(_ note: NoteDocument) -> some View {
        HStack(spacing: 12) {
            Button {
                if selectingNotes { toggleSelection(note.id) } else if !trash { openNotebook(note.id) }
            } label: {
                HStack(spacing: 14) {
                    if let page = store.library.firstPage(in: note.id) { PageThumbnail(page: page, disk: store.disk).frame(width: 40, height: 54).accessibilityHidden(true) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(note.title).font(.headline).foregroundStyle(.primary)
                        Text("\(note.pageIDs.count) pages · \(note.updatedAt.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    NotebookSyncBadge(cloud: store.cloud, note: note)
                    if note.favorite == true { Image(systemName: "star.fill").foregroundStyle(.orange) }
                    if selectingNotes { Image(systemName: selectedNotes.contains(note.id) ? "checkmark.circle.fill" : "circle") }
                }.frame(minHeight: 68).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(trash).accessibilityLabel(note.title).accessibilityIdentifier("library.note.\(note.id.uuidString)")
                .accessibilityValue(trash ? "In Trash" : selectedNotes.contains(note.id) ? "Selected" : "")
            Menu { noteActions(note) } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("Actions for \(note.title)")
        }.padding(12).background(OpenNotesStyle.chrome, in: RoundedRectangle(cornerRadius: 12)).contextMenu { noteActions(note) }
    }
    private func cardTitle(_ title: String) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize { Text(title) }
            else { Text(title).lineLimit(2, reservesSpace: true) }
        }.font(.headline).foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func folderCard(_ folder: NotebookFolder) -> some View {
        let noteCount = store.library.notes.filter { $0.folderID == folder.id && $0.deletedAt == nil }.count
        return VStack(alignment: .leading, spacing: 8) {
            Button { selectedFolderID = folder.id } label: {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "folder.fill").resizable().scaledToFit()
                        .foregroundStyle(OpenNotesStyle.accent).padding(.horizontal, 8).padding(.vertical, 28)
                        .frame(maxWidth: .infinity).frame(height: 192)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityHidden(true)
                    cardTitle(folder.name)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(folder.name)
                .accessibilityHint("Open folder")
                .accessibilityIdentifier("library.folder.\(folder.id.uuidString)")
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(noteCount) notebook\(noteCount == 1 ? "" : "s")")
                    Text("\(folder.childFolderIDs.count) folder\(folder.childFolderIDs.count == 1 ? "" : "s")")
                }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Menu { folderActions(folder) } label: {
                    Label("Actions for \(folder.name)", systemImage: "ellipsis").labelStyle(.iconOnly)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
            }
        }.padding(12).background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color(uiColor: .separator).opacity(0.3)) }
            .contextMenu { folderActions(folder) }
    }
    @ViewBuilder private func folderActions(_ folder: NotebookFolder) -> some View {
        Button("Rename", systemImage: "pencil") { renamedFolder = folder; folderEditorShown = true }
        Button("Move", systemImage: "folder") { movingFolder = folder.id; movingDocuments = []; moveShown = true }
        Button("Delete folder", systemImage: "trash", role: .destructive) { folderDeletion = folder }
    }
    private func noteCard(_ note: NoteDocument) -> some View {
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                if selectingNotes { toggleSelection(note.id) }
                else if !trash { openNotebook(note.id) }
            } label: {
                VStack(alignment: .leading, spacing: 12) {
                    Group {
                        if let page = store.library.firstPage(in: note.id) { PageThumbnail(page: page, disk: store.disk) }
                        else { Image(systemName: "doc").resizable().scaledToFit().foregroundStyle(.tertiary) }
                    }.padding(14).frame(maxWidth: .infinity).frame(height: 202)
                        .background(Color(UIColor(presetHex: note.colorHex ?? "") ?? .secondarySystemBackground).opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(Color(UIColor(presetHex: note.colorHex ?? "#315BB1") ?? .systemBlue)).frame(width: 5).padding(.vertical, 8) }
                        .accessibilityHidden(true)
                    cardTitle(note.title)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(trash)
                .accessibilityLabel(note.title)
                .accessibilityValue(trash ? "In Trash" : selectedNotes.contains(note.id) ? "Selected" : "")
                .accessibilityIdentifier("library.note.\(note.id.uuidString)")
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(note.pageIDs.count) page\(note.pageIDs.count == 1 ? "" : "s")")
                    Text(note.updatedAt, style: .date)
                }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                NotebookSyncBadge(cloud: store.cloud, note: note)
                if selectingNotes { Image(systemName: selectedNotes.contains(note.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(OpenNotesStyle.accent) }
                if note.favorite == true { Image(systemName: "star.fill").foregroundStyle(.orange).accessibilityLabel("Favorite") }
                Menu { noteActions(note) } label: {
                    Label("Actions for \(note.title)", systemImage: "ellipsis").labelStyle(.iconOnly)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
            }
            if trash { Text("In Trash · Restore from the menu").font(.caption).foregroundStyle(.secondary) }
        }.padding(12).background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color(uiColor: .separator).opacity(0.3), lineWidth: 1) }
            .contextMenu { noteActions(note) }
    }
    private var folderBreadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                Button { selectedFolderID = nil } label: { Text("Documents").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }
                if let currentFolderID {
                    ForEach(store.library.folderPath(to: currentFolderID).filter { $0.id != store.library.folders.first?.id }) { folder in
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        Button { selectedFolderID = folder.id } label: { Text(folder.name).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }
                    }
                }
            }.font(.subheadline)
        }
    }
    private func openNotebook(_ id: UUID) {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        if workspace == nil { workspace = NotebookWorkspace(store: store) }
        let previous = lastOpening
        lastOpening = Task {
            await previous?.value
            await workspace?.select(id)
            if workspace?.active == id { path = [id] }
        }
    }
    private func consumeInbox() async {
        guard store.ready, !consumingInbox else { return }
        consumingInbox = true; defer { consumingInbox = false }
        do {
            for url in try ShareInbox.pending() {
                let receipt = url.deletingLastPathComponent().lastPathComponent
                let id: UUID
                if let existing = store.library.sharedImports[receipt] { id = existing }
                else {
                    guard let imported = await store.importFile(url, folderID: currentFolderID) else { failedSharedImport = url; break }
                    id = imported
                    store.library.sharedImports[receipt] = id
                    store.persist()
                }
                guard await store.flush() else { failedSharedImport = url; break }
                try ShareInbox.remove(url)
                failedSharedImport = nil
                store.library.sharedImports[receipt] = nil; store.persist()
                openNotebook(id)
            }
        } catch {
            // Unsigned/local-only builds may not have an App Group container.
            if (error as NSError).code != CocoaError.fileReadNoPermission.rawValue { store.error = "Shared import: \(error.localizedDescription)" }
        }
    }
    private var newNoteButton: some View {
        Button { newNotebookShown = true } label: { Label("New notebook", systemImage: "plus").fixedSize(horizontal: false, vertical: true).foregroundStyle(Color(uiColor: .systemBackground)) }
            .labelStyle(.titleAndIcon).buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle).controlSize(.large)
            .accessibilityIdentifier("library.create")
            .keyboardShortcut("n", modifiers: .command)
    }
    @ViewBuilder private func noteActions(_ note: NoteDocument) -> some View {
        if trash {
            Button("Restore notebook", systemImage: "arrow.uturn.backward") { store.restoreNote(note.id) }
        } else {
            Button("Move to…", systemImage: "folder") { movingFolder = nil; movingDocuments = [note.id]; moveShown = true }
            Button("Rename", systemImage: "pencil") { title = note.title; rename = note }
            Button(note.favorite == true ? "Remove from favorites" : "Add to favorites", systemImage: "star") { store.update(note.id) { $0.favorite = !($0.favorite ?? false) } }
            Button("Move to Trash", systemImage: "trash", role: .destructive) { deletion = [note.id]; deleteShown = true }
        }
    }

}

struct CloudStatusLine: View {
    @ObservedObject var cloud: CloudSync
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if cloud.phase == .syncing { ProgressView().controlSize(.small) }
                else { Image(systemName: cloud.phase.icon) }
                Text(cloud.phase.label)
            }.font(.caption).foregroundStyle(.secondary).frame(minHeight: 44, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library.syncStatus")
        .accessibilityLabel("Sync status: \(cloud.phase.label)")
        .accessibilityValue(cloud.status + (cloud.lastSuccessfulSync.map { ". Last successful sync: " + $0.formatted(date: .abbreviated, time: .shortened) } ?? ". No successful sync yet."))
        .accessibilityHint("Open account and sync details")
    }
}
