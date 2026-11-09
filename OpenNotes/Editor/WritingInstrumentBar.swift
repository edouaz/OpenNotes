import SwiftUI

struct WritingInstrumentBar: View {
    @ObservedObject var session: EditorSession
    var sticky: () -> Void = {}
    @State private var optionsItem: EditorToolSettings.ToolbarItem?
    @State private var sizeItem: Int?
    @State private var colorItem: Int?
    @State private var customizationShown = false
    @State private var stickyOptionsShown = false
    @AppStorage("undoPlacement") private var undoPlacement = "left"
    @AppStorage(Self.positionKey) private var position = "top"
    static let positionKey = "toolbarPosition"
    /// Docked on the left or right edge, the bar runs top to bottom.
    private var vertical: Bool { position == "left" || position == "right" }
    private var arrowEdge: Edge { position == "bottom" ? .bottom : position == "left" ? .leading : position == "right" ? .trailing : .top }
    private var stack: AnyLayout { vertical ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4)) }
    private var separator: some View { Divider().frame(width: vertical ? 24 : nil, height: vertical ? nil : 24) }
    /// Drawing tools and the post-it share one order, so the post-it can sit anywhere among them.
    private var tools: [EditorToolSettings.ToolbarItem] { session.toolSettings.normalizedToolbarOrder.filter { $0.drawingTool != nil || $0 == .stickyNote } }
    private var colors: [String] { session.toolSettings.colors(for: session.selectedTool) }
    private func presented<T: Equatable>(_ value: T, selection: Binding<T?>) -> Binding<Bool> {
        Binding(get: { selection.wrappedValue == value }, set: { if !$0 { selection.wrappedValue = nil } })
    }
    var body: some View {
        (vertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))) {
            if undoPlacement == "left" { stack { historyButtons }.buttonStyle(.plain); separator }
            ScrollView(vertical ? .vertical : .horizontal, showsIndicators: false) {
                stack {
                    ForEach(tools.filter { !session.toolSettings.hiddenTools.contains($0) }) { item in
                        if item == .stickyNote { stickyButton(item) }
                        else if let tool = item.drawingTool {
                            let selected = session.selectedTool == tool && session.stickyInsertionColor == nil
                            Button {
                                session.stickyInsertionColor = nil
                                if selected { optionsItem = item } else { session.selectedTool = tool }
                            } label: {
                                InstrumentLabel(title: item.title, symbol: item.symbol)
                                    .foregroundStyle(selected ? OpenNotesStyle.accent : Color.primary)
                                    .background(selected ? OpenNotesStyle.accent.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 12))
                            }.accessibilityAddTraits(selected ? .isSelected : [])
                                .accessibilityHint(selected ? "Tap again for options" : "Select tool")
                                .accessibilityIdentifier("editor.tool.\(item.rawValue)")
                                .popover(isPresented: presented(item, selection: $optionsItem), arrowEdge: arrowEdge) {
                                    EditorInstrumentOptions(session: session) { optionsItem = nil }
                                        .compactPopover()
                                }
                        }
                    }
                    if session.stickyInsertionColor != nil {
                    } else if session.selectedTool.isWritingTool || session.selectedTool == .eraser {
                        separator
                        ForEach(0..<3) { index in
                            let preset = session.toolSettings.presets(for: session.selectedTool)[index]
                            let selected = session.selectedStrokePreset == index
                            Button {
                                if selected { sizeItem = index } else { session.selectStrokePreset(index) }
                            } label: {
                                StrokePresetPreview(preset: preset, eraser: session.selectedTool == .eraser, color: session.selectedTool == .eraser ? .primary : session.inkColor, widthScale: session.selectedTool == .marker ? 0.5 : 1)
                                    .frame(width: 44, height: 44)
                                    .background(selected ? OpenNotesStyle.accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
                            }.accessibilityLabel("Stroke size \(index + 1), \(preset.width.formatted()) points")
                                .accessibilityAddTraits(selected ? .isSelected : [])
                                .accessibilityIdentifier("editor.width.\(index + 1)")
                                .popover(isPresented: presented(index, selection: $sizeItem), arrowEdge: arrowEdge) {
                                    StrokePresetEditor(session: session, index: index).compactPopover()
                                }
                        }
                        if session.selectedTool.isWritingTool {
                            separator
                            ForEach(Array(colors.enumerated()), id: \.offset) { index, hex in
                                let selected = session.paperInkColor.presetHex == hex
                                Button {
                                    if selected { colorItem = index } else { session.setInkColor(Color(UIColor(presetHex: hex) ?? .black)) }
                                } label: {
                                    Circle().fill(Color(UIColor(presetHex: hex) ?? .black)).frame(width: 22, height: 22)
                                        .overlay { Circle().strokeBorder(Color.primary.opacity(0.25)) }.frame(width: 44, height: 44)
                                        .background(selected ? OpenNotesStyle.accent.opacity(0.14) : .clear, in: Circle()).contentShape(Rectangle())
                                }.accessibilityLabel("Favorite color \(hex)").accessibilityIdentifier("editor.favorite.\(index)")
                                    .accessibilityAddTraits(selected ? .isSelected : [])
                                    .popover(isPresented: presented(index, selection: $colorItem), arrowEdge: arrowEdge) {
                                        FavoriteColorEditor(session: session, index: index) { colorItem = nil }.compactPopover()
                                    }
                                    .contextMenu {
                                        Button("Move left", systemImage: "arrow.left") { moveColor(index, by: -1) }.disabled(index == 0)
                                        Button("Move right", systemImage: "arrow.right") { moveColor(index, by: 1) }.disabled(index == colors.count - 1)
                                        Button("Remove", systemImage: "trash", role: .destructive) {
                                            var updated = colors; guard updated.indices.contains(index) else { return }
                                            updated.remove(at: index); session.setFavoriteColors(updated)
                                        }
                                    }
                            }
                            Button { colorItem = -1 } label: { InstrumentLabel(title: "Add favorite color", symbol: "plus.circle") }
                                .disabled(colors.count >= 12)
                                .popover(isPresented: presented(-1, selection: $colorItem), arrowEdge: arrowEdge) {
                                    FavoriteColorEditor(session: session, index: nil) { colorItem = nil }.compactPopover()
                                }
                        }
                    }
                    separator
                    Button { customizationShown = true } label: { InstrumentLabel(title: "Customize toolbar", symbol: "ellipsis") }
                        .accessibilityIdentifier("editor.toolbarLayout")
                }.padding(vertical ? .vertical : .horizontal, 12).padding(vertical ? .horizontal : .vertical, 6)
            }.frame(width: vertical ? 58 : nil, height: vertical ? nil : 58).buttonStyle(.plain).accessibilityIdentifier("editor.toolbar.scroll")
            if undoPlacement == "right" { separator; stack { historyButtons }.buttonStyle(.plain) }
        }.background(OpenNotesStyle.chrome)
            .sheet(isPresented: $customizationShown) {
                NavigationStack {
                    List {
                        Section("Layout") {
                            Picker("Toolbar position", selection: $position) {
                                Text("Top").tag("top"); Text("Bottom").tag("bottom"); Text("Left").tag("left"); Text("Right").tag("right")
                            }
                            Picker("Undo and Redo", selection: $undoPlacement) { Text(vertical ? "Top" : "Left").tag("left"); Text(vertical ? "Bottom" : "Right").tag("right") }
                        }
                        customizationSection("Tools · drag to reorder", items: tools)
                        Button("Reset toolbar") { session.toolSettings.toolbarOrder = EditorToolSettings.ToolbarItem.allCases.filter { $0 != .image && $0 != .toolOptions }; session.toolSettings.hiddenTools = [.pencil]; undoPlacement = "left"; position = "top" }
                    }.environment(\.editMode, .constant(.active)).navigationTitle("Customize toolbar")
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { customizationShown = false } } }
                }
            }
    }
    private func stickyButton(_ item: EditorToolSettings.ToolbarItem) -> some View {
        let active = session.stickyInsertionColor != nil
        return Button { if active { stickyOptionsShown = true } else { sticky() } } label: {
            InstrumentLabel(title: item.title, symbol: item.symbol)
                .foregroundStyle(active ? OpenNotesStyle.accent : Color.primary)
                .background(active ? OpenNotesStyle.accent.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 12))
        }.accessibilityAddTraits(active ? .isSelected : [])
            .accessibilityHint(active ? "Tap again for options" : "Select tool, then tap the page")
            .accessibilityIdentifier("editor.tool.stickyNote")
            .popover(isPresented: $stickyOptionsShown, arrowEdge: arrowEdge) { StickyToolOptions(session: session).compactPopover() }
    }
    private func customizationSection(_ title: String, items: [EditorToolSettings.ToolbarItem]) -> some View {
        Section(title) {
            ForEach(items) { item in
                Toggle(item.title, isOn: Binding(get: { !session.toolSettings.hiddenTools.contains(item) }, set: { visible in
                    if visible { session.toolSettings.hiddenTools.remove(item) } else { session.toolSettings.hiddenTools.insert(item) }
                }))
            }.onMove { source, destination in
                var values = items; values.move(fromOffsets: source, toOffset: destination)
                let order = session.toolSettings.normalizedToolbarOrder
                var iterator = values.makeIterator()
                session.toolSettings.toolbarOrder = order.map { items.contains($0) ? iterator.next()! : $0 }
            }
        }
    }
    private func moveColor(_ index: Int, by distance: Int) {
        var updated = colors; let target = index + distance
        guard updated.indices.contains(index), updated.indices.contains(target) else { return }
        updated.swapAt(index, target); session.setFavoriteColors(updated)
    }
    private var historyButtons: some View {
        Group {
            Button { session.canvas.undoManager?.undo() } label: { InstrumentLabel(title: "Undo", symbol: "arrow.uturn.backward") }
                .keyboardShortcut("z", modifiers: .command).disabled(!session.canUndo)
            Button { session.canvas.undoManager?.redo() } label: { InstrumentLabel(title: "Redo", symbol: "arrow.uturn.forward") }
                .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!session.canRedo)
        }
    }
}

private struct InstrumentLabel: View {
    let title: String
    let symbol: String
    var body: some View {
        Label(title, systemImage: symbol).labelStyle(.iconOnly).font(.title3)
            .frame(width: 44, height: 44).contentShape(Rectangle())
    }
}

private struct StrokePresetPreview: View {
    let preset: EditorToolSettings.StrokePreset
    let eraser: Bool
    let color: Color
    var widthScale: Double = 1
    var body: some View {
        if eraser {
            Circle().strokeBorder(color, lineWidth: 1.5).frame(width: min(30, max(6, preset.width * 0.5)), height: min(30, max(6, preset.width * 0.5)))
        } else {
            let width = min(12, max(1, preset.width * widthScale))
            Path { path in path.move(to: CGPoint(x: 2, y: 10)); path.addLine(to: CGPoint(x: 32, y: 10)) }
                .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round,
                                                   dash: preset.pattern == .dashed ? [max(6, width * 2), max(4, width * 1.5)] : (preset.pattern == .dotted ? [0.1, max(4, width * 2)] : [])))
                .frame(width: 34, height: 20)
        }
    }
}

private struct StrokePresetEditor: View {
    @ObservedObject var session: EditorSession
    let index: Int
    private var preset: EditorToolSettings.StrokePreset { session.toolSettings.presets(for: session.selectedTool)[index] }
    private func update(_ change: (inout EditorToolSettings.StrokePreset) -> Void) {
        var value = preset; change(&value); session.toolSettings.setPreset(value, at: index, for: session.selectedTool); session.selectStrokePreset(index)
    }
    var body: some View {
        VStack(spacing: 16) {
            Text("Stroke size \(index + 1)").font(.headline)
            StrokePresetPreview(preset: preset, eraser: session.selectedTool == .eraser, color: session.selectedTool == .eraser ? .primary : session.inkColor, widthScale: session.selectedTool == .marker ? 0.5 : 1).frame(height: 36)
            if session.selectedTool == .pen || session.selectedTool == .fountainPen {
                HStack {
                    ForEach(InkPattern.allCases, id: \.self) { pattern in
                        Button { update { $0.pattern = pattern } } label: {
                            StrokePresetPreview(preset: .init(width: 2, pattern: pattern), eraser: false, color: .primary)
                                .frame(width: 60, height: 44).background(preset.pattern == pattern ? OpenNotesStyle.accent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
                        }.accessibilityIdentifier("editor.pattern.\(pattern.rawValue)").accessibilityLabel(pattern.rawValue.capitalized).accessibilityAddTraits(preset.pattern == pattern ? .isSelected : [])
                    }
                }.buttonStyle(.plain)
            }
            HStack { Text("Thickness"); Spacer(); Text("\(preset.width.formatted(.number.precision(.fractionLength(1)))) pt").monospacedDigit() }
            Slider(value: Binding(get: { preset.width }, set: { width in update { $0.width = width } }), in: session.selectedTool == .eraser ? 4...100 : session.documentInkWidthRange)
                .accessibilityLabel("Thickness")
            HStack { Text(session.selectedTool == .eraser ? "4 pt" : "\(session.documentInkWidthRange.lowerBound.formatted()) pt"); Spacer(); Text(session.selectedTool == .eraser ? "100 pt" : "\(session.documentInkWidthRange.upperBound.formatted()) pt") }.font(.caption).foregroundStyle(.secondary)
        }.padding().frame(width: 260)
    }
}

private struct FavoriteColorEditor: View {
    @ObservedObject var session: EditorSession
    let index: Int?
    let dismiss: () -> Void
    @State private var section = 0
    @State private var custom = Color.black
    private let presets = ["#202725", "#B34242", "#315BB1", "#E59E32", "#4F9B70", "#8B5BA8", "#FFE66D", "#A8E6CF", "#FFAFCC"]
    private func choose(_ color: Color) {
        let hex = UIColor(color).presetHex
        var colors = session.toolSettings.colors(for: session.selectedTool)
        if let index {
            guard colors.indices.contains(index) else { return }
            if let existing = colors.firstIndex(of: hex), existing != index { colors.swapAt(index, existing) }
            else { colors[index] = hex }
        } else if !colors.contains(hex) {
            guard colors.count < 12 else { return }; colors.append(hex)
        }
        session.setFavoriteColors(colors)
        session.setInkColor(color); dismiss()
    }
    var body: some View {
        VStack(spacing: 14) {
            Picker("Color source", selection: $section) { Text("Presets").tag(0); Text("Custom").tag(1); Text("History").tag(2) }
                .pickerStyle(.segmented).accessibilityIdentifier("editor.colorSource")
            if section == 1 {
                ColorPicker("Color", selection: $custom, supportsOpacity: false)
                Button { choose(custom) } label: { Text("Use color").frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle()) }.buttonStyle(.borderedProminent)
            } else {
                let values = section == 0 ? presets : (session.toolSettings.colorHistory ?? [])
                if values.isEmpty { Text("No recent colors").foregroundStyle(.secondary).padding() }
                else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5)) {
                        ForEach(values, id: \.self) { hex in
                            Button { choose(Color(UIColor(presetHex: hex) ?? .black)) } label: {
                                Circle().fill(Color(UIColor(presetHex: hex) ?? .black)).frame(width: 30, height: 30)
                                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.25)))
                                    .overlay { if session.paperInkColor.presetHex == hex { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white).shadow(radius: 2) } }
                                    .frame(width: 44, height: 44).contentShape(Rectangle())
                            }.accessibilityLabel(hex)
                        }
                    }.buttonStyle(.plain)
                }
            }
            Button(action: dismiss) { Text("Cancel").frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle()) }
        }.padding().frame(width: 280).onAppear { custom = session.inkColor }
    }
}

private extension View {
    @ViewBuilder func compactPopover() -> some View {
        if #available(iOS 16.4, *) { self.presentationCompactAdaptation(.popover) }
        else { self }
    }
}
