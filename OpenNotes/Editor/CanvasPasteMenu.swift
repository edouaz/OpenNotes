import UIKit

extension PageScrollView: UIEditMenuInteractionDelegate {
    @objc func showPasteMenu(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        Diagnostics.shared.record("menu.longpress.began", ["enabled": String(longPressMenuEnabled)])
        guard longPressMenuEnabled else { Diagnostics.shared.record("menu.longpress.disabled"); return }
        let point = gesture.location(in: self)
        Diagnostics.shared.record("menu.longpress")
        pasteMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
    }
    func requestSticky(at point: CGPoint) {
        Diagnostics.shared.record("menu.addSticky")
        onAddSticky?(CGPoint(x: (point.x + canvas.contentOffset.x) / canvas.zoomScale, y: (point.y + canvas.contentOffset.y) / canvas.zoomScale))
    }
    func requestPaste(at point: CGPoint) {
        Diagnostics.shared.record("menu.paste", ["zoom": String(format: "%.2f", canvas.zoomScale)])
        let logical = CGPoint(x: (point.x + canvas.contentOffset.x) / canvas.zoomScale, y: (point.y + canvas.contentOffset.y) / canvas.zoomScale)
        onPaste?(logical)
    }
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]) -> UIMenu? {
        let point = configuration.sourcePoint
        if let note = note(at: point), let actions = note.menu?.children {
            Diagnostics.shared.record("menu.note")
            return UIMenu(children: actions)
        }
        let clipboard = UIPasteboard.general
        let available = clipboard.contains(pasteboardTypes: [DocumentClipboard.selectionType, DocumentClipboard.inkType]) || clipboard.hasImages || clipboard.hasStrings
        return UIMenu(children: [
            UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard"), attributes: available ? [] : .disabled) { [weak self] _ in self?.requestPaste(at: point) },
            UIAction(title: "Add Sticky Note", image: UIImage(systemName: "note.text")) { [weak self] _ in self?.requestSticky(at: point) }
        ])
    }
}
