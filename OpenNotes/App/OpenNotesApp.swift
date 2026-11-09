import SwiftUI

@main
struct OpenNotesApp: App {
    @StateObject private var library = LibraryStore()
    @Environment(\.scenePhase) private var phase
    init() { Diagnostics.shared.record("app.launch", ["build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?", "os": UIDevice.current.systemVersion]) }
    var body: some Scene {
        WindowGroup {
            LibraryScreen().environmentObject(library)
                .tint(OpenNotesStyle.accent)
                .onChange(of: phase) {
                    Diagnostics.shared.record("app.phase", ["value": String(describing: $0)])
                    if $0 == .active { library.cloud.foregrounded() }
                    if $0 == .background { library.cloud.flushBeforeBackground() }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in Diagnostics.shared.record("app.memoryWarning") }
        }
    }
}
