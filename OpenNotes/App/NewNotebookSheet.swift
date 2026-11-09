import SwiftUI

struct NewNotebookSheet: View {
    let store: LibraryStore
    let folderID: UUID?
    let created: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var template = AppPreferences.defaultTemplate
    @State private var landscape = AppPreferences.defaultLandscape
    @State private var cover = Color.blue
    @State private var saving = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Notebook") {
                    TextField("Title", text: $title).accessibilityIdentifier("library.new.title")
                    ColorPicker("Cover color", selection: $cover, supportsOpacity: false)
                }
                Section("First page") {
                    Picker("Paper", selection: $template) {
                        ForEach(PageTemplate.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Landscape A4", isOn: $landscape)
                    Text("A4 paper · You can change the paper later in the notebook menu.").font(.footnote).foregroundStyle(.secondary)
                }
                if saving { ProgressView("Creating notebook…") }
                if let error = store.error { Text(error).foregroundStyle(.red).accessibilityLabel("Creation error: \(error)") }
            }
            .navigationTitle("New notebook").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) { Button("Create") { Task { await create() } }.disabled(saving).accessibilityIdentifier("library.new.confirm") }
            }
        }.interactiveDismissDisabled(saving)
    }
    private func create() async {
        saving = true; defer { saving = false }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = await store.create(title: name.isEmpty ? "New notebook" : name, folderID: folderID) else { return }
        store.update(id) { $0.colorHex = UIColor(cover).presetHex }
        // The last choice becomes the default page style.
        UserDefaults.standard.set(template.rawValue, forKey: "defaultPageTemplate")
        UserDefaults.standard.set(landscape, forKey: "defaultLandscape")
        if var page = store.library.firstPage(in: id) {
            AppPreferences.applyDefaultStyle(to: &page)
            store.updatePage(page)
        }
        guard await store.flush() else { return }
        dismiss(); created(id)
    }
}
