import SwiftUI

struct EditorInstrumentOptions: View {
    @ObservedObject var session: EditorSession
    var done: () -> Void
    @State private var clearShown = false
    private var isPen: Bool { session.selectedTool == .pen || session.selectedTool == .fountainPen }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if session.selectedTool.isWritingTool {
                            writingOptions
                        } else if session.selectedTool == .eraser {
                            eraserOptions
                        } else {
                            lassoOptions
                        }
                    }.padding(16)
                }
                .background(Color(uiColor: .systemGroupedBackground))
                .accessibilityIdentifier("instrument.options.scroll")
            }
            .navigationTitle("Instrument").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("Done", action: done) }
            }
        }
        .frame(idealWidth: 320, idealHeight: isPen ? 350 : (session.selectedTool == .marker ? 210 : 430))
        .presentationDetents([.large])
        .confirmationDialog("Clear editable content on this page?", isPresented: $clearShown, titleVisibility: .visible) {
            Button("Clear page", role: .destructive) { Task { _ = await session.clearPage() } }
        } message: { Text("The paper and original PDF stay intact. You can undo this action.") }
    }

    @ViewBuilder private var writingOptions: some View {
        if isPen {
            optionSection("Pen type") {
                HStack(spacing: 8) {
                    penStyleButton(.ballpoint, title: "Ballpoint", symbol: "pencil.tip")
                    penStyleButton(.fountain, title: "Fountain", symbol: "pencil.tip.crop.circle")
                    penStyleButton(.brush, title: "Brush", symbol: "paintbrush.pointed")
                }
                .accessibilityIdentifier("instrument.penStyle")
            }
        }
        if session.selectedTool == .pencil {
            optionSection("Apple Pencil") {
                Toggle("Pressure", isOn: Binding(get: { session.toolSettings.pressureEnabled ?? true }, set: { session.toolSettings.pressureEnabled = $0 }))
                    .accessibilityIdentifier("instrument.pressureEnabled")
                Toggle("Tilt", isOn: Binding(get: { session.toolSettings.tiltEnabled ?? true }, set: { session.toolSettings.tiltEnabled = $0 }))
                    .accessibilityIdentifier("instrument.tiltEnabled")
            }
        } else {
            optionSection("Stabilization") {
                HStack {
                    Text("Stabilization")
                    Spacer()
                    Text("\(Int(session.toolSettings.stabilization(for: session.selectedTool))) %")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: {
                    session.toolSettings.stabilization(for: session.selectedTool)
                }, set: { session.toolSettings.setStabilization($0, for: session.selectedTool) }), in: 0...100, step: 1)
                    .accessibilityLabel("Stabilization")
            }
        }
    }

    private func penStyleButton(_ style: EditorToolSettings.PenStyle, title: String, symbol: String) -> some View {
        choiceButton(title, symbol: symbol, selected: session.toolSettings.penStyle == style) {
            session.toolSettings.applyPenPreset(style)
        }
    }

    private var eraserOptions: some View {
        optionSection("Eraser mode") {
            HStack(spacing: 8) {
                eraserModeButton(.stroke, title: "Stroke", symbol: "scribble")
                eraserModeButton(.standard, title: "Standard", symbol: "eraser")
                eraserModeButton(.precision, title: "Precision", symbol: "eraser.line.dashed")
            }
            .accessibilityIdentifier("instrument.eraser.mode")
            Toggle("Erase pen and pencil", isOn: Binding(get: { session.toolSettings.erasePen != false }, set: { session.toolSettings.erasePen = $0 }))
            Toggle("Erase highlighter", isOn: Binding(get: { session.toolSettings.eraseHighlighter != false }, set: { session.toolSettings.eraseHighlighter = $0 }))
            Toggle("Return to previous tool", isOn: Binding(get: { session.toolSettings.eraserAutoDeselect == true }, set: { session.toolSettings.eraserAutoDeselect = $0 }))
            Button(role: .destructive) { clearShown = true } label: { Text("Clear page").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }
        }
    }

    private func eraserModeButton(_ mode: EditorToolSettings.EraserMode, title: String, symbol: String) -> some View {
        let current = session.toolSettings.eraserMode
        let selected = current == mode || (mode == .standard && (current == .pixel || current == .intelligent))
        return choiceButton(title, symbol: symbol, selected: selected) { session.toolSettings.eraserMode = mode }
    }

    private func choiceButton(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.title3)
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 54)
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .background(selected ? Color.accentColor.opacity(0.15) : Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
    @ViewBuilder private var lassoOptions: some View {
        optionSection("Outline") {
            Picker("Selection shape", selection: $session.toolSettings.lassoShape) {
                Text("Freeform").tag(EditorToolSettings.LassoShape.freeform)
                Text("Rectangle").tag(EditorToolSettings.LassoShape.rectangle)
            }.pickerStyle(.segmented)
        }
        optionSection("Include in selection") {
            Toggle("Handwriting", isOn: $session.toolSettings.includeHandwriting)
            Toggle("Text", isOn: Binding(get: { session.toolSettings.includeText != false }, set: { session.toolSettings.includeText = $0 }))
            Toggle("Images", isOn: $session.toolSettings.includeImages)
            Toggle("Sticky note", isOn: $session.toolSettings.includeStickyNotes)
            Text("Outline an area with Apple Pencil, then drag it. Long press the selection with a finger to resize or rotate it.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
    private func optionSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
            content()
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}
