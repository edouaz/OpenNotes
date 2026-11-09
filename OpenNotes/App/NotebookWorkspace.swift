import SwiftUI

@MainActor
final class NotebookWorkspace: ObservableObject {
    @Published var tabs: [UUID] = []
    @Published var active: UUID?
    @Published var error: String?
    private var sessions: [UUID: EditorSession] = [:]
    private var switching = false
    let store: LibraryStore
    init(store: LibraryStore) { self.store = store }
    func session(_ id: UUID) -> EditorSession {
        if let session = sessions[id] { return session }
        let session = EditorSession(store: store, noteID: id)
        sessions[id] = session
        return session
    }
    func select(_ id: UUID) async {
        guard !switching, let note = store.library.note(id: id), note.deletedAt == nil, active != id else { return }
        Diagnostics.shared.record("workspace.change", ["active": active?.uuidString ?? "none"])
        switching = true; defer { switching = false }
        if let active, let old = sessions[active] {
            guard await old.flush() else { error = old.error; return }
            old.cancelOCR()
            old.backgroundData = nil; old.resources = [:]; old.artwork = nil
        }
        if !tabs.contains(id) { tabs.append(id) }
        active = id
        save()
    }
    func close(_ id: UUID) async {
        guard !switching, let index = tabs.firstIndex(of: id) else { return }
        Diagnostics.shared.record("workspace.change", ["active": active?.uuidString ?? "none"])
        switching = true; defer { switching = false }
        if let session = sessions[id], !(await session.flush()) { error = session.error; return }
        tabs.removeAll { $0 == id }; sessions[id] = nil
        if active == id { active = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)] }
        save()
    }
    func restore() async {
        var seen = Set<UUID>()
        tabs = (UserDefaults.standard.stringArray(forKey: "openNotebooks") ?? []).compactMap(UUID.init(uuidString:)).filter { store.library.note(id: $0)?.deletedAt == nil && store.library.note(id: $0) != nil && seen.insert($0).inserted }
        let selected = UserDefaults.standard.string(forKey: "activeNotebook").flatMap(UUID.init(uuidString:))
        active = selected.flatMap { tabs.contains($0) ? $0 : nil } ?? tabs.last
    }
    func save() {
        UserDefaults.standard.set(tabs.map(\.uuidString), forKey: "openNotebooks")
        UserDefaults.standard.set(active?.uuidString, forKey: "activeNotebook")
    }
    func returnToLibrary() async {
        guard !switching else { return }
        Diagnostics.shared.record("workspace.change", ["active": active?.uuidString ?? "none"])
        switching = true; defer { switching = false }
        if let active, let session = sessions[active], !(await session.flush()) { error = session.error; return }
        active = nil; save()
    }
}

struct NotebookWorkspaceView: View {
    @ObservedObject var workspace: NotebookWorkspace
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            NotebookTabs(workspace: workspace, store: workspace.store) { dismiss() }
            if let id = workspace.active {
                EditorScreen(store: workspace.store, noteID: id, session: workspace.session(id)).id(id)
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .alert("Could not save", isPresented: Binding(
            get: { workspace.error != nil },
            set: { if !$0 { workspace.error = nil } }
        )) {
            Button("OK") { workspace.error = nil }
        } message: {
            Text(workspace.error ?? "")
        }
    }
}

private struct NotebookTabs: View {
    @ObservedObject var workspace: NotebookWorkspace
    @ObservedObject var store: LibraryStore
    let didCloseLastTab: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var renamedID: UUID?
    @State private var title = ""

    /// Which edge the active tab scrolled past, if any: it is then pinned there so it never leaves the screen.
    private enum PinnedEdge { case none, leading, trailing }
    @State private var pinned = PinnedEdge.none
    private struct ActiveTabFrame: PreferenceKey {
        static var defaultValue: CGRect? = nil
        static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = nextValue() ?? value }
    }

    private func tab(_ id: UUID) -> NotebookTab {
        NotebookTab(
            title: store.library.note(id: id)?.title ?? "Notebook",
            id: id,
            selected: workspace.active == id,
            select: { Task { await workspace.select(id) } },
            rename: {
                title = store.library.note(id: id)?.title ?? ""
                renamedID = id
            },
            close: {
                Task {
                    await workspace.close(id)
                    if workspace.active == nil { didCloseLastTab() }
                }
            }
        )
    }

    var body: some View {
        GeometryReader { geometry in
            // The library button stays put; only the tabs scroll. 8 + 48 + 4 = its padding, width and gap.
            let rowWidth = max(0, geometry.size.width - 8 - 48 - 4)
            let tabWidth = OpenNotesStyle.notebookTabWidth(availableWidth: max(0, rowWidth - 8), count: workspace.tabs.count, spacing: 4)
            HStack(spacing: 4) {
                Button {
                    Task { await workspace.returnToLibrary(); if workspace.active == nil { didCloseLastTab() } }
                } label: {
                    Label("Library", systemImage: "square.grid.2x2").labelStyle(.iconOnly).frame(width: 48, height: 44)
                }.buttonStyle(.plain).accessibilityIdentifier("workspace.library").padding(.leading, 8)
                ScrollViewReader { reader in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(workspace.tabs, id: \.self) { id in
                                tab(id)
                                    .frame(width: tabWidth)
                                    .background {
                                        if workspace.active == id {
                                            GeometryReader { Color.clear.preference(key: ActiveTabFrame.self, value: $0.frame(in: .named("tabs"))) }
                                        }
                                    }
                                    .id(id)
                            }
                        }.padding(.trailing, 8).padding(.vertical, 4)
                    }
                    .coordinateSpace(name: "tabs")
                    .onPreferenceChange(ActiveTabFrame.self) { frame in
                        let edge: PinnedEdge = frame.map { $0.minX < -1 ? .leading : $0.maxX > rowWidth + 1 ? .trailing : .none } ?? .none
                        if edge != pinned { pinned = edge }
                    }
                    .overlay(alignment: pinned == .leading ? .leading : .trailing) {
                        if pinned != .none, let active = workspace.active {
                            tab(active).frame(width: tabWidth)
                                .background(OpenNotesStyle.rail, in: RoundedRectangle(cornerRadius: 12))
                                .shadow(color: .black.opacity(0.12), radius: 4)
                                .padding(.vertical, 4)
                                .simultaneousGesture(TapGesture().onEnded { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { reader.scrollTo(active) } })
                        }
                    }
                    .task(id: "\(workspace.active?.uuidString ?? "")-\(geometry.size.width)") {
                        await Task.yield()
                        if let active = workspace.active, !Task.isCancelled {
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { reader.scrollTo(active) }
                        }
                    }
                }
            }
        }
        .frame(height: 52)
        .background(OpenNotesStyle.rail)
        .overlay(alignment: .bottom) { Divider() }
        .alert("Rename notebook", isPresented: Binding(
            get: { renamedID != nil }, set: { if !$0 { renamedID = nil } }
        )) {
            TextField("Title", text: $title)
            Button("Save") {
                if let id = renamedID {
                    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    store.update(id) { $0.title = trimmed.isEmpty ? "Untitled" : trimmed }
                }
                renamedID = nil
            }
            Button("Cancel", role: .cancel) { renamedID = nil }
        }
    }
}

private struct NotebookTab: View {
    let title: String
    let id: UUID
    let selected: Bool
    let select: () -> Void
    let rename: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: select) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.leading, 12).contentShape(Rectangle())
            }
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("workspace.tab.\(id.uuidString)")
            Menu { Button("Rename", systemImage: "pencil", action: rename) } label: {
                Label("Options for \(title)", systemImage: "chevron.down")
                    .labelStyle(.iconOnly).frame(width: 44, height: 44).contentShape(Rectangle())
            }.accessibilityIdentifier("workspace.options.\(id.uuidString)")
            Button(action: close) {
                Label("Close \(title)", systemImage: "xmark")
                    .labelStyle(.iconOnly).frame(width: 44, height: 44).contentShape(Rectangle())
            }.accessibilityHint("Close the tab and keep the notebook")
        }
        .buttonStyle(.plain)
        .background(selected ? OpenNotesStyle.chrome : .clear, in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .bottom) {
            if selected { Rectangle().fill(OpenNotesStyle.accent).frame(height: 2).padding(.horizontal, 12) }
        }
    }
}
