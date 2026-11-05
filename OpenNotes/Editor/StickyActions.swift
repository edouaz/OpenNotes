import UIKit

@MainActor
extension EditorSession {
    @discardableResult
    func stickyAction(_ action: PageSelectionAction, id: UUID) async -> Bool {
        pendingDocumentActions += 1; defer { pendingDocumentActions -= 1 }
        guard [.duplicateSelection, .bringFront, .sendBack, .lockSelection].contains(action),
              !isReadOnly, let pageID = page?.id, await flush(), let page, page.id == pageID,
              let note = page.elements?.first(where: { $0.id == id && $0.kind == .stickyNote }) else { return false }
        let all = page.elements ?? []
        var ids: Set<UUID> = [id]
        var count = 0
        while count != ids.count {
            count = ids.count
            for item in all where item.parentID.map({ ids.contains($0) }) == true { ids.insert(item.id) }
        }
        let selected = all.filter { ids.contains($0.id) }
        let strokes = canvas.drawing.strokes.filter { $0.parentID.map { ids.contains($0) } == true }
        guard action == .lockSelection || (!selected.contains { $0.isLocked == true } && !strokes.contains { $0.isLocked == true }) else { return false }
        if action == .duplicateSelection {
            let sorted = all.enumerated().sorted { ($0.element.zIndex ?? Double($0.offset)) < ($1.element.zIndex ?? Double($1.offset)) }.map(\.element)
            let originals = sorted.filter { ids.contains($0.id) }
            let remapped = Dictionary(uniqueKeysWithValues: originals.map { ($0.id, UUID()) })
            let fullBounds = originals.reduce(CGRect.null) { bounds, item in
                bounds.union(CGRect(x: item.x, y: item.y, width: item.width, height: item.height))
            }
            let size = PageRenderer.size(page)
            let dx = min(20, max(0, size.width - fullBounds.maxX))
            let dy = min(20, max(0, size.height - fullBounds.maxY))
            let copies = originals.map { source in
                var item = source
                item.id = remapped[source.id]!
                item.parentID = source.parentID.flatMap { remapped[$0] }
                item.x += dx; item.y += dy
                return item
            }
            var copiedInk = InkDrawing(strokes: strokes).transformed(using: CGAffineTransform(translationX: dx, y: dy))
            for index in copiedInk.strokes.indices {
                copiedInk.strokes[index].id = UUID()
                copiedInk.strokes[index].parentID = copiedInk.strokes[index].parentID.flatMap { remapped[$0] }
            }
            var ordered = sorted + copies
            for index in ordered.indices { ordered[index].zIndex = Double(index) }
            replaceContent(InkDrawing(strokes: canvas.drawing.strokes + copiedInk.strokes), elements: ordered, actionName: "Duplicate sticky note")
        } else if action == .lockSelection {
            let locking = note.isLocked != true
            let elements = all.map { source in
                var item = source
                if ids.contains(item.id) { item.isLocked = locking }
                return item
            }
            var drawing = canvas.drawing
            for index in drawing.strokes.indices where drawing.strokes[index].parentID.map({ ids.contains($0) }) == true { drawing.strokes[index].isLocked = locking }
            replaceContent(drawing, elements: elements, actionName: locking ? "Lock sticky note" : "Unlock sticky note")
        } else {
            let sorted = all.enumerated().sorted { ($0.element.zIndex ?? Double($0.offset)) < ($1.element.zIndex ?? Double($1.offset)) }.map(\.element)
            let group = sorted.filter { ids.contains($0.id) }, others = sorted.filter { !ids.contains($0.id) }
            var ordered = action == .bringFront ? others + group : group + others
            for index in ordered.indices { ordered[index].zIndex = Double(index) }
            replaceContent(canvas.drawing, elements: ordered, actionName: "Arrange sticky note")
        }
        guard error == nil else { return false }
        return await flush()
    }
}
