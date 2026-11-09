import UIKit

@MainActor
extension EditorSession {
    func replaceDrawing(_ replacement: InkDrawing, actionName: String) {
        guard !isReadOnly else { return }
        let replacement = actionName == "Draw" ? attachingInk(replacement) : replacement
        let previous = canvas.drawing
        registerDrawingUndo(previous, actionName: actionName)
        canvas.drawing = replacement
        changed(replacement)
        refreshUndoAvailability()
    }

    func registerDrawingUndo(_ previous: InkDrawing, actionName: String) {
        canvas.undoManager?.registerUndo(withTarget: self) { session in session.replaceDrawing(previous, actionName: actionName) }
        canvas.undoManager?.setActionName(actionName)
    }

    @discardableResult
    func moveSelection(inside path: UIBezierPath, by requested: CGPoint, durable: Bool = true) async -> Bool {
        pendingDocumentActions += 1; defer { pendingDocumentActions -= 1 }
        let end = Perf.begin("lasso.move"); defer { end() }
        guard !isReadOnly, requested.x.isFinite, requested.y.isFinite, let pageID = page?.id,
              await prepareEdit(durable: durable), let original = page, original.id == pageID else { return false }
        let snapshot = selectionSnapshot(original, path: path)
        guard !snapshot.isEmpty, !snapshot.containsLockedObjects else { return false }
        let delta = snapshot.clamped(requested)
        guard delta != .zero else { return false }
        let moved = (original.elements ?? []).map { element in
            var element = element
            if snapshot.elementIDs.contains(element.id) { element.x += delta.x; element.y += delta.y }
            return element
        }
        let strokes = canvas.drawing.strokes.enumerated().map { index, stroke in
            guard snapshot.strokeIndices.contains(index) else { return stroke }
            return InkDrawing(strokes: [stroke]).transformed(using: CGAffineTransform(translationX: delta.x, y: delta.y)).strokes[0]
        }
        let reattached = reattachingMovedInk(strokes, moved: snapshot.strokeIDs, elements: moved, movedElements: snapshot.elementIDs)
        replaceContent(InkDrawing(strokes: reattached), elements: moved, actionName: "Move selection", attachObjects: true)
        return durable ? await flush() : true
    }

    @discardableResult
    func transformSelection(inside path: UIBezierPath, scale: CGFloat, deleting: Bool = false) async -> Bool {
        pendingDocumentActions += 1; defer { pendingDocumentActions -= 1 }
        let end = Perf.begin("lasso.transform"); defer { end() }
        guard !isReadOnly, scale.isFinite, (0.1...10).contains(scale), await flush(), let original = page else { return false }
        let drawing = canvas.drawing
        let snapshot = selectionSnapshot(original, path: path)
        let elements = snapshot.elements
        let selected = drawing.strokes.indices.map { snapshot.strokeIndices.contains($0) }
        guard selected.contains(true) || !elements.isEmpty, !snapshot.containsLockedObjects else { return false }
        let ids = snapshot.elementIDs
        var bounds = CGRect.null
        for (index, stroke) in drawing.strokes.enumerated() where selected[index] { bounds = bounds.union(stroke.renderBounds) }
        for item in elements { bounds = bounds.union(item.visibleBounds) }
        let size = PageRenderer.size(original)
        let factor = min(scale, size.width / max(1, bounds.width), size.height / max(1, bounds.height))
        let x = min(max(0, bounds.midX - bounds.width * factor / 2), size.width - bounds.width * factor)
        let y = min(max(0, bounds.midY - bounds.height * factor / 2), size.height - bounds.height * factor)
        let transform = CGAffineTransform(a: factor, b: 0, c: 0, d: factor, tx: x - bounds.minX * factor, ty: y - bounds.minY * factor)
        var updated: [PageElement] = []
        for var item in original.elements ?? [] {
            if ids.contains(item.id) {
                if deleting { continue }
                item.x = item.x * factor + transform.tx; item.y = item.y * factor + transform.ty
                item.width *= factor; item.height *= factor
                if item.kind == .text { item.textFontSize = min(96, max(8, (item.textFontSize ?? 20) * factor)) }
            }
            updated.append(item)
        }
        let strokes = drawing.strokes.enumerated().compactMap { index, stroke -> InkStroke? in
            guard selected[index] else { return stroke }
            return deleting ? nil : InkDrawing(strokes: [stroke]).transformed(using: transform).strokes.first
        }
        replaceContent(InkDrawing(strokes: strokes), elements: updated, actionName: deleting ? "Delete selection" : "Resize selection")
        return await flush()
    }
}

/// What a selection contains, fixed when it is made: moving it over other ink never picks that ink up.
struct SelectionIdentity: Equatable {
    var strokeIDs: Set<UUID>
    var elementIDs: Set<UUID>
}

@MainActor
extension EditorSession {
    /// The current selection's content: by identity once captured, otherwise from the outline.
    func selectionSnapshot(_ page: NotePage, path: UIBezierPath) -> SelectionMoveSnapshot {
        if let selectionIDs { return SelectionMoveSnapshot(page: page, drawing: canvas.drawing, selection: selectionIDs, settings: toolSettings) }
        return SelectionMoveSnapshot(page: page, drawing: canvas.drawing, path: path, settings: toolSettings)
    }
}

// Shared by the drag preview and the committed edit, including page-edge constraints.
struct SelectionMoveSnapshot {
    let strokeIndices: Set<Int>
    let strokeIDs: Set<UUID>
    let elementIDs: Set<UUID>
    let ink: InkDrawing
    let elements: [PageElement]
    let bounds: CGRect
    let pageSize: CGSize
    let containsLockedObjects: Bool
    let alignObjects: Bool
    let alignmentX: [CGFloat]
    let alignmentY: [CGFloat]
    var isEmpty: Bool { strokeIndices.isEmpty && elementIDs.isEmpty }

    init(page: NotePage, drawing: InkDrawing, path: UIBezierPath, settings: EditorToolSettings) {
        let end = Perf.begin("lasso.snapshot"); defer { end() }
        let selectedElements = DocumentClipboard.selectedElements(page, inside: path, settings: settings)
        var selectedIDs = Set(selectedElements.map(\.id))
        // A selected parent owns its descendants, independently of lasso filters.
        var changed = true
        while changed {
            let old = selectedIDs.count
            for item in page.elements ?? [] where item.parentID.map({ selectedIDs.contains($0) }) == true { selectedIDs.insert(item.id) }
            changed = old != selectedIDs.count
        }
        let occlusion = StickyInkOcclusion(page.elements ?? [])
        let hiddenParents = page.collapsedContentParents
        let edges = DocumentClipboard.edges(of: path.cgPath)
        let indices = Set(drawing.strokes.indices.filter { index in
            let stroke = drawing.strokes[index]
            if stroke.parentID.map({ selectedIDs.contains($0) }) == true { return true }
            // Occlusion only removes geometry, so a raw miss is final: the path booleans run only for hits.
            guard settings.includeHandwriting, stroke.parentID.map({ !hiddenParents.contains($0) }) != false,
                  DocumentClipboard.contains(stroke, inside: path, edges: edges),
                  let visible = occlusion.visible(stroke) else { return false }
            return visible.vectorOutline == stroke.vectorOutline || DocumentClipboard.contains(visible, inside: path, edges: edges)
        })
        self.init(page: page, drawing: drawing, elementIDs: selectedIDs, strokeIndices: indices, settings: settings)
    }

    /// Rebuilds a captured selection against the current document; deleted objects simply drop out.
    init(page: NotePage, drawing: InkDrawing, selection: SelectionIdentity, settings: EditorToolSettings) {
        var selectedIDs = selection.elementIDs.intersection((page.elements ?? []).map(\.id))
        var changed = true
        while changed {
            let old = selectedIDs.count
            for item in page.elements ?? [] where item.parentID.map({ selectedIDs.contains($0) }) == true { selectedIDs.insert(item.id) }
            changed = old != selectedIDs.count
        }
        let indices = Set(drawing.strokes.indices.filter { index in
            let stroke = drawing.strokes[index]
            return selection.strokeIDs.contains(stroke.id) || stroke.parentID.map { selectedIDs.contains($0) } == true
        })
        self.init(page: page, drawing: drawing, elementIDs: selectedIDs, strokeIndices: indices, settings: settings)
    }

    var identity: SelectionIdentity { SelectionIdentity(strokeIDs: strokeIDs, elementIDs: elementIDs) }

    private init(page: NotePage, drawing: InkDrawing, elementIDs selectedIDs: Set<UUID>, strokeIndices indices: Set<Int>, settings: EditorToolSettings) {
        let lockedParents = Set((page.elements ?? []).filter { $0.isLocked == true }.map(\.id))
        containsLockedObjects = !lockedParents.isDisjoint(with: selectedIDs) || indices.contains { index in
            drawing.strokes[index].isLocked == true || drawing.strokes[index].parentID.map { lockedParents.contains($0) } == true
        }
        strokeIndices = indices
        strokeIDs = Set(indices.map { drawing.strokes[$0].id })
        ink = InkDrawing(strokes: drawing.strokes.enumerated().filter { indices.contains($0.offset) }.map(\.element))
        elements = (page.elements ?? []).filter { selectedIDs.contains($0.id) }
        elementIDs = selectedIDs
        var rect = ink.strokes.isEmpty ? CGRect.null : ink.bounds
        for item in elements { rect = rect.union(item.visibleBounds) }
        bounds = rect
        pageSize = PageRenderer.size(page)
        alignObjects = settings.alignObjects ?? true
        let neighbours = (page.elements ?? []).filter { !selectedIDs.contains($0.id) }.map(\.visibleBounds)
        alignmentX = ([CGFloat.zero, pageSize.width / 2, pageSize.width] + neighbours.flatMap { [$0.minX, $0.midX, $0.maxX] }).sorted()
        alignmentY = ([CGFloat.zero, pageSize.height / 2, pageSize.height] + neighbours.flatMap { [$0.minY, $0.midY, $0.maxY] }).sorted()
    }

    func snap(_ delta: CGPoint, tolerance: CGFloat) -> (CGPoint, CGPoint?) {
        guard alignObjects, !isEmpty else { return (clamped(delta), nil) }
        func nearest(_ value: CGFloat, in values: [CGFloat]) -> CGFloat? {
            var low = 0, high = values.count
            while low < high { let middle = (low + high) / 2; if values[middle] < value { low = middle + 1 } else { high = middle } }
            return [low - 1, low].filter { values.indices.contains($0) }.map { values[$0] }.min { abs($0 - value) < abs($1 - value) }
        }
        func axis(_ anchors: [CGFloat], targets: [CGFloat], movement: CGFloat) -> (CGFloat, CGFloat?) {
            let matches = anchors.compactMap { anchor -> (CGFloat, CGFloat)? in
                guard let target = nearest(anchor + movement, in: targets), abs(target - anchor - movement) <= tolerance else { return nil }
                return (target - anchor, target)
            }
            guard let match = matches.min(by: { abs($0.0 - movement) < abs($1.0 - movement) }) else { return (movement, nil) }
            return match
        }
        let x = axis([bounds.minX, bounds.midX, bounds.maxX], targets: alignmentX, movement: delta.x)
        let y = axis([bounds.minY, bounds.midY, bounds.maxY], targets: alignmentY, movement: delta.y)
        let snapped = clamped(CGPoint(x: x.0, y: y.0))
        return (snapped, x.1 == nil && y.1 == nil ? nil : CGPoint(x: x.1 ?? .nan, y: y.1 ?? .nan))
    }

    func clamped(_ delta: CGPoint) -> CGPoint {
        guard !isEmpty, delta.x.isFinite, delta.y.isFinite else { return .zero }
        return CGPoint(x: min(max(delta.x, -bounds.minX), max(-bounds.minX, pageSize.width - bounds.maxX)),
                       y: min(max(delta.y, -bounds.minY), max(-bounds.minY, pageSize.height - bounds.maxY)))
    }
}
