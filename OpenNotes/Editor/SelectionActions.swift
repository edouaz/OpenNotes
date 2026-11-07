import UIKit

@MainActor
extension EditorSession {
    func pasteSelection(at point: CGPoint) async -> Bool {
        pendingDocumentActions += 1; defer { pendingDocumentActions -= 1 }
        guard let data = UIPasteboard.general.data(forPasteboardType: DocumentClipboard.selectionType) else { return false }
        guard !isReadOnly, await flush(), let page else { return true }
        do {
            let (ink, elements, assets) = try DocumentClipboard.decode(data, on: page, at: point, centered: true)
            for (name, data) in assets { try await store.disk.write(data, name: name) }
            guard self.page?.id == page.id else { throw CocoaError(.userCancelled) }
            resources.merge(assets) { _, new in new }
            replaceContent(InkDrawing(strokes: canvas.drawing.strokes + ink.strokes), elements: (page.elements ?? []) + elements, actionName: "Paste selection")
            _ = await flush()
        } catch { self.error = error.localizedDescription }
        return true
    }

    func selectionAction(_ action: PageSelectionAction, path: UIBezierPath) async {
        pendingDocumentActions += 1; defer { pendingDocumentActions -= 1 }
        guard !isReadOnly, await flush(), let page else { return }
        let snapshot = selectionSnapshot(page, path: path)
        guard !snapshot.isEmpty else { return }
        do {
            if action == .copySelection || action == .cutSelection || action == .duplicateSelection {
                let payload = try DocumentClipboard.payload(snapshot, resources: resources)
                let data = try DocumentClipboard.encode(payload)
                if action == .duplicateSelection {
                    let (ink, elements, assets) = try DocumentClipboard.decode(data, on: page, at: CGPoint(x: snapshot.bounds.minX + 20, y: snapshot.bounds.minY + 20))
                    for (name, bytes) in assets { try await store.disk.write(bytes, name: name) }
                    resources.merge(assets) { _, new in new }
                    replaceContent(InkDrawing(strokes: canvas.drawing.strokes + ink.strokes), elements: (page.elements ?? []) + elements, actionName: "Duplicate selection")
                } else {
                    let fallback = try PageRenderer.capture(page, data: backgroundData, drawing: canvas.drawing, resources: resources, rect: snapshot.bounds)
                    var item: [String: Any] = [DocumentClipboard.selectionType: data]
                    if let png = fallback.pngData() { item["public.png"] = png }
                    UIPasteboard.general.setItems([item], options: [.localOnly: true])
                    if action == .cutSelection {
                        guard !snapshot.containsLockedObjects else { return }
                        replaceContent(InkDrawing(strokes: canvas.drawing.strokes.enumerated().filter { !snapshot.strokeIndices.contains($0.offset) }.map(\.element)), elements: (page.elements ?? []).filter { !snapshot.elementIDs.contains($0.id) }, actionName: "Cut selection")
                    }
                }
            } else if action == .recolorSelection {
                guard !snapshot.containsLockedObjects else { return }
                var ink = canvas.drawing
                for index in ink.strokes.indices where snapshot.strokeIndices.contains(index) { ink.strokes[index].ink.color = paperInkColor }
                let elements = try (page.elements ?? []).map { source -> PageElement in
                    guard snapshot.elementIDs.contains(source.id), source.kind != .image else { return source }
                    var item = source
                    switch item.kind {
                    case .text:
                        item.textColorHex = paperInkColor.presetHex
                        if item.richTextRTF != nil {
                            let text = NSMutableAttributedString(attributedString: RichTextDocument.attributed(item))
                            text.addAttribute(.foregroundColor, value: paperInkColor, range: NSRange(location: 0, length: text.length))
                            item.richTextRTF = try RichTextDocument.encode(text)
                        }
                    case .stickyNote: item.fillColorHex = paperInkColor.presetHex
                    default: item.strokeColorHex = paperInkColor.presetHex
                    }
                    return item
                }
                replaceContent(ink, elements: elements, actionName: "Recolor selection")
            } else if action == .lockSelection {
                let locking = !snapshot.containsLockedObjects
                let elements = (page.elements ?? []).map { source in
                    var item = source
                    if snapshot.elementIDs.contains(item.id) { item.isLocked = locking }
                    return item
                }
                var ink = canvas.drawing
                for index in ink.strokes.indices where snapshot.strokeIndices.contains(index) { ink.strokes[index].isLocked = locking }
                replaceContent(ink, elements: elements, actionName: locking ? "Lock selection" : "Unlock selection")
            } else if action == .bringFront || action == .sendBack {
                guard !snapshot.containsLockedObjects else { return }
                let elements = page.elements ?? []
                let selected = elements.filter { snapshot.elementIDs.contains($0.id) }
                let other = elements.filter { !snapshot.elementIDs.contains($0.id) }
                var ordered = action == .bringFront ? other + selected : selected + other
                for index in ordered.indices { ordered[index].zIndex = Double(index) }
                replaceContent(canvas.drawing, elements: ordered, actionName: "Arrange selection")
            } else if action == .collapseSelection {
                let elements = (page.elements ?? []).map { source in
                    var item = source
                    if snapshot.elementIDs.contains(item.id), item.kind == .stickyNote, item.isLocked != true { item.collapsed = !(item.collapsed ?? false) }
                    return item
                }
                replaceContent(canvas.drawing, elements: elements, actionName: "Collapse sticky note")
            }
            _ = await flush()
        } catch { self.error = error.localizedDescription }
    }

    @discardableResult
    func affineSelection(inside path: UIBezierPath, scale: CGFloat, rotation: CGFloat, scaleY: CGFloat? = nil, anchor: CGPoint? = nil, durable: Bool = true) async -> Bool {
        pendingDocumentActions += 1; defer { pendingDocumentActions -= 1 }
        let end = Perf.begin("lasso.affine"); defer { end() }
        guard !isReadOnly, scale.isFinite, rotation.isFinite, (0.1...10).contains(scale), await prepareEdit(durable: durable), let page else { return false }
        let snapshot = selectionSnapshot(page, path: path)
        guard !snapshot.isEmpty, !snapshot.containsLockedObjects else { return false }
        let sy = scaleY ?? scale
        guard sy.isFinite, (0.1...10).contains(sy) else { return false }
        let center = anchor ?? CGPoint(x: snapshot.bounds.midX, y: snapshot.bounds.midY)
        guard center.x.isFinite, center.y.isFinite else { return false }
        let a = cos(rotation) * scale, b = sin(rotation) * scale
        let c = -sin(rotation) * sy, d = cos(rotation) * sy
        let transform = CGAffineTransform(a: a, b: b, c: c, d: d, tx: center.x - a * center.x - c * center.y, ty: center.y - b * center.x - d * center.y)
        let size = PageRenderer.size(page)
        let elements = (page.elements ?? []).map { source -> PageElement in
            guard snapshot.elementIDs.contains(source.id) else { return source }
            var item = source
            let oldCenter = CGPoint(x: item.x + item.width / 2, y: item.y + item.height / 2).applying(transform)
            item.width *= scale; item.height *= sy
            item.x = oldCenter.x - item.width / 2; item.y = oldCenter.y - item.height / 2
            item.rotation = (item.rotation ?? 0) + rotation
            return item
        }
        guard elements.allSatisfy({ $0.x >= 0 && $0.y >= 0 && $0.x + $0.width <= size.width && $0.y + $0.height <= size.height }) else { return false }
        let ink = canvas.drawing.strokes.enumerated().map { index, stroke in
            snapshot.strokeIndices.contains(index) ? InkDrawing(strokes: [stroke]).transformed(using: transform).strokes[0] : stroke
        }
        replaceContent(InkDrawing(strokes: ink), elements: elements, actionName: rotation == 0 ? "Resize selection" : "Rotate selection")
        return durable ? await flush() : true
    }
}
