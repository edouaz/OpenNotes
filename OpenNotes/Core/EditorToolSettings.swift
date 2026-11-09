import Foundation

struct EditorToolSettings: Codable, Equatable {
    enum PenStyle: String, Codable, CaseIterable { case ballpoint, fountain, brush }
    enum EraserMode: String, Codable, CaseIterable { case stroke, precision, standard, pixel, intelligent }
    enum LassoShape: String, Codable, CaseIterable { case freeform, rectangle }
    enum ToolbarItem: String, Codable, CaseIterable, Identifiable {
        case pen, pencil, marker, eraser, lasso, image, stickyNote, toolOptions
        var id: Self { self }
        var title: String {
            switch self {
            case .pen: return "Pen"
            case .pencil: return "Pencil"
            case .marker: return "Highlighter"
            case .eraser: return "Eraser"
            case .lasso: return "Lasso"
            case .image: return "Image"
            case .stickyNote: return "Sticky note"
            case .toolOptions: return "Tool options"
            }
        }
        var symbol: String {
            switch self {
            case .pen: return "pencil.tip"
            case .pencil: return "pencil"
            case .marker: return "highlighter"
            case .eraser: return "eraser"
            case .lasso: return "lasso"
            case .image: return "photo"
            case .stickyNote: return "note.text"
            case .toolOptions: return "slider.horizontal.3"
            }
        }
        var drawingTool: DrawingToolKind? { DrawingToolKind(rawValue: rawValue) }
    }

    var penStyle = PenStyle.ballpoint
    var tipSharpness: Double?
    var inkPattern: InkPattern?
    var stabilization = 0.0
    // Optional additions preserve decoding of settings saved before the Goodnotes adaptation.
    var stabilizationByStyle: [String: Double]?
    var pressureSensitivity: Double?
    var pressureEnabled: Bool?
    var tiltEnabled: Bool?
    var rulerEnabled: Bool?
    var markerTiltEnabled: Bool?
    var penPressureEnabled: Bool { pressureEnabled ?? (penStyle != .ballpoint) }

    mutating func applyPenPreset(_ style: PenStyle) {
        penStyle = style
        pressureEnabled = style != .ballpoint
    }

    func stabilizationKey(for tool: DrawingToolKind) -> String {
        tool == .marker ? "marker" : penStyle.rawValue
    }
    func stabilization(for tool: DrawingToolKind) -> Double {
        stabilizationByStyle?[stabilizationKey(for: tool)] ?? stabilization
    }
    mutating func setStabilization(_ value: Double, for tool: DrawingToolKind) {
        if stabilizationByStyle == nil { stabilizationByStyle = [:] }
        let key = stabilizationKey(for: tool)
        stabilizationByStyle?[key] = value
    }
    var eraserMode = EraserMode.stroke
    var eraserWidth = 24.0
    var erasePen: Bool?
    var eraseHighlighter: Bool?
    var eraserAutoDeselect: Bool?
    var alignObjects: Bool?
    var lassoShape = LassoShape.freeform
    var includeHandwriting = true
    var includeText: Bool?
    var includeImages = true
    var includeStickyNotes = true
    var shapeRecognitionEnabled = true
    var shapeAngleSnap: Bool?
    var toolbarOrder = ToolbarItem.allCases.filter { $0 != .image && $0 != .toolOptions }
    var hiddenTools: Set<ToolbarItem> = [.pencil]
    var favoriteColors: [String: [String]] = [:]
    var toolbarFavoriteColors: [String]?
    var instrumentFavoriteColors: [String: [String]]?
    var showSelectionResizeHandles: Bool?
    var stickyColorHex: String?
    var stickyCard: Bool?
    struct StrokePreset: Codable, Equatable {
        var width: Double
        var pattern: InkPattern = .solid
    }
    var strokePresets: [String: [StrokePreset]]?
    var selectedStrokePresets: [String: Int]?
    var colorHistory: [String]?

    func presets(for tool: DrawingToolKind) -> [StrokePreset] {
        let defaults: [Double] = tool == .eraser ? [12, 24, 48] : (tool == .marker ? [4, 12, 24] : [1, 3, 6])
        let saved = strokePresets?[tool.rawValue]
        guard let saved, saved.count == 3, saved.allSatisfy({ $0.width.isFinite && (tool == .eraser ? (4...100) : (tool == .marker ? (2...128) : (0.5...32))).contains($0.width) }) else {
            return defaults.map { StrokePreset(width: $0) }
        }
        return saved
    }
    mutating func setPreset(_ preset: StrokePreset, at index: Int, for tool: DrawingToolKind) {
        guard (0..<3).contains(index) else { return }
        var values = presets(for: tool)
        values[index] = preset
        if strokePresets == nil { strokePresets = [:] }
        strokePresets?[tool.rawValue] = values
    }
    mutating func rememberColor(_ hex: String) {
        colorHistory = Array(([hex] + (colorHistory ?? []).filter { $0 != hex }).prefix(20))
    }

    var normalizedToolbarOrder: [ToolbarItem] {
        var seen = Set<ToolbarItem>()
        return (toolbarOrder + ToolbarItem.allCases).filter { $0 != .image && $0 != .toolOptions && seen.insert($0).inserted }
    }

    func colors(for tool: DrawingToolKind) -> [String] {
        let key = tool == .fountainPen ? "pen" : tool.rawValue
        let defaults = tool == .marker ? ["#FFE66D", "#A8E6CF", "#FFAFCC"] : ["#202725", "#B34242", "#315BB1"]
        let stored = instrumentFavoriteColors?[key] ?? (key == "pen" ? toolbarFavoriteColors : nil) ?? favoriteColors[key] ?? defaults
        var seen = Set<String>()
        return stored.map { $0.uppercased() }.filter { seen.insert($0).inserted }
    }
    mutating func setColors(_ colors: [String], for tool: DrawingToolKind) {
        let key = tool == .fountainPen ? "pen" : tool.rawValue
        if instrumentFavoriteColors == nil { instrumentFavoriteColors = [:] }
        instrumentFavoriteColors?[key] = colors
    }
}
