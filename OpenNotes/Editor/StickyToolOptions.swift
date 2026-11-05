import SwiftUI

/// Defaults for new sticky notes. Opens when the active Post-it tool is tapped again,
/// like every other tool; nothing is repeated on the notes themselves.
struct StickyToolOptions: View {
    @ObservedObject var session: EditorSession
    static let colors = ["#FFE66D", "#A8E6CF", "#FFAFCC", "#A9D6FF", "#D9B8FF"]
    private var color: String { session.toolSettings.stickyColorHex ?? Self.colors[0] }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Post-it").font(.headline)
            HStack(spacing: 12) {
                ForEach(Self.colors, id: \.self) { hex in
                    Button {
                        session.toolSettings.stickyColorHex = hex
                        if session.stickyInsertionColor != nil { session.stickyInsertionColor = hex }
                    } label: {
                        Circle().fill(Color(UIColor(presetHex: hex) ?? .yellow)).frame(width: 30, height: 30)
                            .overlay { Circle().strokeBorder(Color.primary.opacity(0.2)) }
                            .overlay { if hex == color { Image(systemName: "checkmark").font(.footnote.bold()).foregroundStyle(.black.opacity(0.7)) } }
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .accessibilityLabel("Sticky color \(hex)").accessibilityAddTraits(hex == color ? .isSelected : [])
                }
            }
            Picker("Style", selection: Binding(get: { session.toolSettings.stickyCard == true }, set: { session.toolSettings.stickyCard = $0 })) {
                Text("Paper").tag(false)
                Text("Card").tag(true)
            }.pickerStyle(.segmented)
            Text("Applies to new post-its. To restyle an existing one, press and hold it and choose Customize.")
                .font(.footnote).foregroundStyle(.secondary)
        }.padding(16).frame(minWidth: 300)
    }
}
