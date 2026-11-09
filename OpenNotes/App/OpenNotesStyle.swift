import SwiftUI

enum OpenNotesStyle {
    // Calibration defaults; these are OpenNotes tokens, not measured Goodnotes values.
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.43, green: 0.69, blue: 1, alpha: 1)
            : UIColor(red: 0.12, green: 0.36, blue: 0.76, alpha: 1)
    })
    static let canvas = Color(uiColor: .systemGroupedBackground)
    static let chrome = Color(uiColor: .secondarySystemGroupedBackground)
    static let rail = Color(uiColor: .secondarySystemBackground)
    static let controlSize: CGFloat = 44
    static let cornerRadius: CGFloat = 14

    /// Tabs share the row equally (1 = full, 2 = halves … 4 = quarters); past four they keep a
    /// quarter of the row (never under 140pt) and the row scrolls. `spacing` follows each tab.
    static func notebookTabWidth(availableWidth: CGFloat, count: Int, spacing: CGFloat = 0) -> CGFloat {
        guard count > 0, availableWidth > 0 else { return 0 }
        let shared = availableWidth / CGFloat(max(2, min(count, 4))) - spacing   // a lone tab takes half the row
        return max(min(140, availableWidth - spacing), shared)
    }
}
