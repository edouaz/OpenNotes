import SwiftUI
import Darwin

struct DiagnosticsScreen: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("debugLogging") private var enabled = true
    @State private var exporting = false
    @State private var share: ShareFile?
    @State private var error: String?
    @State private var clearing = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Diagnostic mode") {
                    Toggle("Record events", isOn: $enabled)
                        .onChange(of: enabled) { Diagnostics.shared.setEnabled($0) }
                    Text("Enabled by default for this test version. Stores startup, navigation, saves, errors and technical settings locally. No text, image, notebook name or handwriting is recorded.").font(.footnote)
                }
                Section("Share an issue") {
                    Button { Task { await export() } } label: { Label(exporting ? "Preparing…" : "Export logs / AirDrop", systemImage: "square.and.arrow.up") }.disabled(exporting)
                    Text("Reproduce the issue, export the JSON file, then choose AirDrop or Save to Files. Recent events are preserved across launches; nothing is uploaded automatically.").font(.footnote)
                    Text("After a native crash, also attach the OpenNotes .ips report from iPad Settings → Privacy & Security → Analytics & Improvements → Analytics Data. Logs describe the interaction but do not replace the crash stack trace.").font(.footnote)
                }
                Section("Local storage") {
                    Text("Rotating log limited to approximately 1 MB. Recent events may be missing after an abrupt interruption.").font(.footnote)
                    Button("Clear logs", role: .destructive) { clearing = true }
                }
            }.navigationTitle("Diagnostic").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Close") { dismiss() } }
                .sheet(item: $share) { ActivitySheet(url: $0.url) }
                .alert("Diagnostic", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
                .confirmationDialog("Clear local logs?", isPresented: $clearing, titleVisibility: .visible) {
                    Button("Clear", role: .destructive) { Task { do { try await Diagnostics.shared.clear() } catch { self.error = error.localizedDescription } } }
                }
        }
    }
    private func export() async {
        exporting = true; defer { exporting = false }
        var system = utsname(); uname(&system)
        let machine = withUnsafePointer(to: &system.machine) { pointer in pointer.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) } }
        let defaults = UserDefaults.standard
        let metadata = ["version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
                        "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
                        "bundle": Bundle.main.bundleIdentifier ?? "?", "os": UIDevice.current.systemVersion,
                        "machine": machine, "toolbar": "OpenNotes",
                        "fingerDrawing": String(defaults.bool(forKey: "fingerDrawing")), "verticalPaging": String(defaults.bool(forKey: "verticalPaging")),
                        "lowPowerMode": String(ProcessInfo.processInfo.isLowPowerModeEnabled),
                        "idiom": UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone",
                        "screen": "\(Int(UIScreen.main.bounds.width))x\(Int(UIScreen.main.bounds.height))@\(Int(UIScreen.main.scale))x",
                        "reduceMotion": String(UIAccessibility.isReduceMotionEnabled),
                        "textSize": UIApplication.shared.preferredContentSizeCategory.rawValue,
                        "locale": Locale.current.identifier, "debugLogging": String(Diagnostics.shared.enabled)]
        Diagnostics.shared.record("diagnostics.export")
        do { share = ShareFile(url: try await Diagnostics.shared.export(metadata: metadata)) }
        catch { self.error = error.localizedDescription }
    }
}
