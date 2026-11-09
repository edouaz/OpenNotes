import SwiftUI
import Darwin

/// App-wide switches, read where each feature runs. Defaults keep every feature on.
enum AppPreferences {
    private static var defaults: UserDefaults { .standard }
    private static func flag(_ key: String) -> Bool { defaults.object(forKey: key) as? Bool ?? true }
    /// Saves, syncs and refreshes previews less often. Also on while iPadOS Low Power Mode is.
    static var batterySaver: Bool { defaults.bool(forKey: "batterySaver") || ProcessInfo.processInfo.isLowPowerModeEnabled }
    static var scratchOutErase: Bool { flag("scratchOutErase") }
    static var circleToSelect: Bool { flag("circleToSelect") }
    static var hoverPreview: Bool { flag("hoverPreview") && !batterySaver }
    static var smartSearch: Bool { flag("smartSearch") }
    static var swipePaging: Bool { flag("swipePaging") }
    static var doubleTapFit: Bool { flag("doubleTapFit") }
    static var shapeHaptics: Bool { flag("shapeHaptics") }
    /// Predicted Pencil samples draw slightly ahead of the tip; off in battery saver (less work per frame).
    static var pencilPrediction: Bool { flag("pencilPrediction") && !batterySaver }
    static var measureFrames: Bool { flag("measureFrames") && !batterySaver }
    /// Seconds of pause before writing edits to disk.
    static var autosaveDelay: Double { batterySaver ? max(5, number("autosaveDelay", 1.5)) : number("autosaveDelay", 1.5) }
    /// Seconds after a save before syncing to the cloud.
    static var syncDelay: Double { batterySaver ? max(45, number("syncDelay", 5)) : number("syncDelay", 5) }
    /// Sharp tiles when zoomed in cost memory and rendering; battery saver keeps one level less.
    static var sharpZoom: Bool { flag("sharpZoom") && !batterySaver }
    private static func number(_ key: String, _ fallback: Double) -> Double {
        let value = defaults.object(forKey: key) as? Double ?? fallback
        return value.isFinite && value > 0 ? value : fallback
    }
    /// Lift shadows and similar decoration; off in battery saver.
    static var visualEffects: Bool { flag("visualEffects") && !batterySaver }
    /// Paper for new notebooks and for pages added after a PDF or at the end; remembered across launches.
    static var defaultTemplate: PageTemplate { defaults.string(forKey: "defaultPageTemplate").flatMap(PageTemplate.init(rawValue:)) ?? .grid }
    static var defaultLandscape: Bool { defaults.bool(forKey: "defaultLandscape") }
    static func applyDefaultStyle(to page: inout NotePage) {
        page.template = defaultTemplate
        let size = PageRenderer.size(page)
        if defaultLandscape != (size.width > size.height) { page.width = size.height; page.height = size.width }
    }
    /// 1 = strict; higher accepts rougher triangles, rectangles and circles. Default slightly relaxed.
    static var shapeTolerance: CGFloat { CGFloat(defaults.object(forKey: "shapeTolerance") as? Double ?? 1.25) }
    /// Degrees within which lines and edges lock to horizontal or vertical.
    static var shapeAxisLock: CGFloat { CGFloat(defaults.object(forKey: "shapeAxisLock") as? Double ?? 8) }
}

struct DiagnosticsScreen: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("debugLogging") private var enabled = true
    @AppStorage("batterySaver") private var batterySaver = false
    @AppStorage("scratchOutErase") private var scratchOutErase = true
    @AppStorage("circleToSelect") private var circleToSelect = true
    @AppStorage("hoverPreview") private var hoverPreview = true
    @AppStorage("visualEffects") private var visualEffects = true
    @AppStorage("defaultPageTemplate") private var defaultTemplate = PageTemplate.grid
    @AppStorage("defaultLandscape") private var defaultLandscape = false
    @AppStorage("smartSearch") private var smartSearch = true
    @AppStorage("swipePaging") private var swipePaging = true
    @AppStorage("doubleTapFit") private var doubleTapFit = true
    @AppStorage("shapeHaptics") private var shapeHaptics = true
    @AppStorage("pencilPrediction") private var pencilPrediction = true
    @AppStorage("measureFrames") private var measureFrames = true
    @AppStorage("sharpZoom") private var sharpZoom = true
    @AppStorage("autosaveDelay") private var autosaveDelay = 1.5
    @AppStorage("syncDelay") private var syncDelay = 5.0
    @AppStorage("shapeTolerance") private var shapeTolerance = 1.25
    @AppStorage("shapeAxisLock") private var shapeAxisLock = 8.0
    @State private var exporting = false
    @State private var share: ShareFile?
    @State private var error: String?
    @State private var clearing = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Default page style") {
                    Picker("Paper", selection: $defaultTemplate) { ForEach(PageTemplate.allCases) { Text($0.title).tag($0) } }
                    Toggle("Landscape", isOn: $defaultLandscape)
                    Text("Used for new notebooks, pages added at the end, and pages added after a PDF or image page.").font(.footnote)
                }
                Section("Battery") {
                    Toggle("Battery saver", isOn: $batterySaver)
                    Text("Saves at most every 5 s and syncs at most every 45 s, checks the cloud every 2 min, refreshes page previews less, renders lighter page-turn previews and zoom tiles, and turns off Pencil prediction, hover cursor, frame measuring and decorative effects. Writing, erasing and scrolling stay fully smooth. Turns on by itself while iPadOS Low Power Mode is on.").font(.footnote)
                }
                Section("Search") {
                    Toggle("Smart search", isOn: $smartSearch)
                    Text("Case and accents are always ignored. Smart search also finds every word of the query in any order, plurals, word beginnings and small typos; exact matches come first.").font(.footnote)
                }
                Section("Gestures") {
                    Toggle("Swipe to turn pages", isOn: $swipePaging)
                    Toggle("Double-tap to fit the page", isOn: $doubleTapFit)
                    Toggle("Haptic tick when a shape is recognized", isOn: $shapeHaptics)
                }
                Section("Features") {
                    Toggle("Scribble over ink to erase it", isOn: $scratchOutErase)
                    Toggle("Hold on a drawn circle to select", isOn: $circleToSelect)
                    Toggle("Pencil hover cursor", isOn: $hoverPreview)
                    Toggle("Visual effects (lift shadows)", isOn: $visualEffects)
                }
                Section("Shapes (hold at the end of a stroke)") {
                    VStack(alignment: .leading) {
                        Text("Detection: \(shapeTolerance < 1.1 ? "strict" : shapeTolerance < 1.45 ? "relaxed" : "very relaxed")")
                        Slider(value: $shapeTolerance, in: 1...1.8, step: 0.05) { Text("Detection") } minimumValueLabel: { Text("Strict").font(.caption) } maximumValueLabel: { Text("Relaxed").font(.caption) }
                    }
                    VStack(alignment: .leading) {
                        Text(shapeAxisLock < 0.5 ? "Horizontal / vertical lock: off" : "Horizontal / vertical lock: within \(Int(shapeAxisLock))°")
                        Slider(value: $shapeAxisLock, in: 0...15, step: 1) { Text("Axis lock") } minimumValueLabel: { Text("Off").font(.caption) } maximumValueLabel: { Text("Strong").font(.caption) }
                    }
                    Text("Relaxed detection turns rough triangles and rectangles into shapes more often, and nearly round ovals into perfect circles.").font(.footnote)
                }
                Section("Advanced") {
                    Stepper("Save after \(autosaveDelay.formatted(.number.precision(.fractionLength(1)))) s pause", value: $autosaveDelay, in: 0.5...10, step: 0.5)
                    Stepper("Sync \(Int(syncDelay)) s after saving", value: $syncDelay, in: 2...120, step: 1)
                    Toggle("Pencil prediction (lower latency)", isOn: $pencilPrediction)
                    Toggle("Sharpest zoom tiles", isOn: $sharpZoom)
                    Toggle("Measure frame drops for logs", isOn: $measureFrames)
                    Text("Longer delays use less battery; a save still happens when you leave the notebook or the app. Settings that the battery saver overrides apply again when it is off.").font(.footnote)
                }
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
            }.navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
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
