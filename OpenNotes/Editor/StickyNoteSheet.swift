import SwiftUI

struct StickyNoteSheet: View {
    @ObservedObject var session: EditorSession
    @State var note: PageElement
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var saving = false
    @StateObject private var formatting = RichTextFormatting()
    @State private var fontSize = 16.0
    @State private var textColor = Color.black
    @State private var backgroundColor = Color.yellow
    @State private var borderColor = Color.black
    @State private var family = "Helvetica"

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    preview
                    (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout())) {
                        Button {
                            note.stickyCornerRadius = 0
                            note.stickyShadow = 0.12
                            note.strokeWidth = nil
                        } label: {
                            Label("Paper", systemImage: isPaper ? "checkmark.circle.fill" : "circle")
                        }.accessibilityAddTraits(isPaper ? .isSelected : [])
                        Button {
                            note.stickyCornerRadius = 16
                            note.stickyShadow = 0.06
                            note.strokeWidth = 1
                            note.strokeColorHex = "#808080"
                            borderColor = Color(UIColor(presetHex: "#808080") ?? .gray)
                        } label: {
                            Label("Card", systemImage: isCard ? "checkmark.circle.fill" : "circle")
                        }.accessibilityAddTraits(isCard ? .isSelected : [])
                    }
                    .buttonStyle(.borderless)
                    Picker("Corners", selection: Binding(get: { note.stickyRadius }, set: { note.stickyCornerRadius = $0 })) {
                        Text("Square").tag(0.0)
                        Text("Slightly rounded").tag(6.0)
                        Text("Rounded").tag(16.0)
                    }
                    ColorPicker("Background", selection: $backgroundColor, supportsOpacity: false)
                        .onChange(of: backgroundColor) { note.fillColorHex = UIColor($0).presetHex }
                    DisclosureGroup("More appearance options") {
                        LabeledContent("Background opacity", value: "\(Int(note.stickyBackgroundOpacity * 100))%")
                        Slider(value: Binding(get: { note.stickyBackgroundOpacity }, set: { note.stickyOpacity = $0 }), in: 0...1)
                            .accessibilityLabel("Background opacity")
                        LabeledContent("Border width", value: String(format: "%.1f pt", note.stickyBorderWidth))
                        Slider(value: Binding(get: { note.stickyBorderWidth }, set: { note.strokeWidth = $0 < 0.5 ? nil : $0 }), in: 0...16, step: 0.5)
                            .accessibilityLabel("Border width")
                        ColorPicker("Border color", selection: $borderColor, supportsOpacity: false)
                            .onChange(of: borderColor) { note.strokeColorHex = UIColor($0).presetHex }
                        LabeledContent("Shadow", value: "\(Int(note.stickyShadowOpacity * 100))%")
                        Slider(value: Binding(get: { note.stickyShadowOpacity }, set: { note.stickyShadow = $0 }), in: 0...0.3)
                            .accessibilityLabel("Shadow opacity")
                    }
                }.disabled(note.isLocked == true)

                Section("Text") {
                    StickyRichTextEditor(item: $note, formatting: formatting)
                        .frame(minHeight: 220)
                        .listRowBackground(Color(UIColor(presetHex: note.fillColorHex ?? "#FFEB80") ?? .systemYellow).opacity(note.stickyBackgroundOpacity))
                    DisclosureGroup("Text formatting") {
                        Text("Applies to the selected range").font(.caption).foregroundStyle(.secondary)
                        (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout())) {
                            Button("Bold") { formatting.trait(.traitBold) }.fontWeight(.bold)
                            Button("Italic") { formatting.trait(.traitItalic) }.italic()
                            Button("Underline") { formatting.toggle(.underlineStyle) }.underline()
                            Button("Strike") { formatting.toggle(.strikethroughStyle) }.strikethrough()
                        }.buttonStyle(.borderless)
                        Picker("Font", selection: $family) {
                            ForEach(["Helvetica", "Georgia", "Courier"], id: \.self) { Text($0) }
                        }.onChange(of: family) { formatting.font($0) }
                        Stepper("Font size: \(Int(fontSize))", value: $fontSize, in: 8...96)
                            .onChange(of: fontSize) { formatting.font(size: $0) }
                        ColorPicker("Text color", selection: $textColor, supportsOpacity: false)
                            .onChange(of: textColor) { formatting.color(UIColor($0)) }
                        (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout())) {
                            Button { formatting.align(.left) } label: { Image(systemName: "text.alignleft") }.accessibilityLabel("Align left")
                            Button { formatting.align(.center) } label: { Image(systemName: "text.aligncenter") }.accessibilityLabel("Align center")
                            Button { formatting.align(.right) } label: { Image(systemName: "text.alignright") }.accessibilityLabel("Align right")
                            Button("Bullets") { formatting.list(numbered: false) }
                            Button("Numbered") { formatting.list(numbered: true) }
                        }.buttonStyle(.borderless)
                    }
                }.disabled(note.isLocked == true)

                Section {
                    Toggle("Lock sticky note", isOn: Binding(get: { note.isLocked == true }, set: { note.isLocked = $0 }))
                    Toggle("Collapse sticky note", isOn: Binding(get: { note.collapsed == true }, set: { note.collapsed = $0 })).disabled(note.isLocked == true)
                    DisclosureGroup("Size and rotation") {
                        LabeledContent("Rotation", value: "\(Int((note.rotation ?? 0) * 180 / .pi))°")
                        Slider(value: Binding(get: { (note.rotation ?? 0) * 180 / .pi }, set: { note.rotation = $0 * .pi / 180 }), in: -180...180)
                            .accessibilityLabel("Sticky note rotation")
                        if let page = session.page {
                            LabeledContent("Width", value: "\(Int(note.width)) pt")
                            Slider(value: $note.width, in: 1...max(1, (page.width ?? 794) - note.x), step: 1).accessibilityLabel("Sticky note width")
                            LabeledContent("Height", value: "\(Int(note.height)) pt")
                            Slider(value: $note.height, in: 1...max(1, (page.height ?? 1123) - note.y), step: 1).accessibilityLabel("Sticky note height")
                        }
                    }.disabled(note.isLocked == true)
                }
                Button("Delete sticky note", role: .destructive) {
                    guard let page = session.page else { return }
                    saving = true
                    Task { let saved = await session.apply(.init(pageID: page.id, kind: .removeElement, elementID: note.id)); saving = false; if saved { dismiss() } }
                }
                .disabled(note.isLocked == true)
            }.disabled(saving).navigationTitle("Sticky note")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") {
                        guard let page = session.page else { return }
                        saving = true
                        Task { let saved = await session.apply(.init(pageID: page.id, kind: .upsertElement, element: note)); saving = false; if saved { dismiss() } }
                    }.disabled(saving || note.text.count > 100_000) }
                }
        }.interactiveDismissDisabled(saving)
            .onAppear {
                backgroundColor = Color(UIColor(presetHex: note.fillColorHex ?? "#FFEB80") ?? .systemYellow)
                borderColor = Color(note.strokeColorHex.flatMap(UIColor.init(presetHex:)) ?? .black)
                fontSize = note.textFontSize ?? 16
                textColor = Color(note.textColorHex.flatMap(UIColor.init(presetHex:)) ?? .black)
            }
    }

    private var isPaper: Bool {
        note.stickyRadius == 0 && note.stickyShadowOpacity == 0.12 && note.stickyBorderWidth == 0
    }

    private var isCard: Bool {
        note.stickyRadius == 16 && note.stickyShadowOpacity == 0.06 && note.stickyBorderWidth == 1 && note.strokeColorHex?.uppercased() == "#808080"
    }

    private var preview: some View {
        let scale = note.collapsed == true ? 1 : min(150 / max(1, note.width), 90 / max(1, note.height))
        let shape = RoundedRectangle(cornerRadius: note.stickyRadius * scale)
        return HStack {
            Spacer()
            ZStack(alignment: .topLeading) {
                shape.fill(backgroundColor.opacity(note.stickyBackgroundOpacity))
                    .shadow(color: .black.opacity(note.stickyShadowOpacity), radius: 5 * scale, y: 2 * scale)
                shape.strokeBorder(borderColor, lineWidth: note.stickyBorderWidth * scale)
                Group {
                    if note.collapsed == true {
                        Image(systemName: "note.text").foregroundStyle(.secondary).padding(8)
                    } else {
                        // This miniature follows document scale; editing controls use Dynamic Type.
                        Text(note.text).font(.system(size: max(1, (note.textFontSize ?? 16) * scale))).foregroundColor(textColor).padding(8 * scale)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipShape(shape)
            }
            .frame(width: note.collapsed == true ? 44 : max(1, note.width) * scale,
                   height: note.collapsed == true ? 44 : max(1, note.height) * scale)
            .rotationEffect(.radians(note.rotation ?? 0))
            Spacer()
        }
        .frame(minHeight: 160)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sticky note appearance preview")
    }
}
