import UIKit

// Images stay standard PNG; editable ink uses its own pasteboard type.
enum DocumentClipboard {
    static let inkType = "fr.catnotes.drawing"
    static let selectionType = "fr.catnotes.selection"
    static let maximumBytes = 20_000_000
    static func filteredPage(_ page: NotePage, settings: EditorToolSettings) -> NotePage {
        var filtered = page
        filtered.elements?.removeAll { item in
            (item.kind == .text && settings.includeText == false) || (item.kind == .image && !settings.includeImages) || (item.kind == .stickyNote && !settings.includeStickyNotes)
        }
        return filtered
    }
    static func selectedElements(_ page: NotePage, inside path: UIBezierPath, settings: EditorToolSettings) -> [PageElement] {
        let ordered = (page.elements ?? []).enumerated().sorted {
            ($0.element.zIndex ?? Double($0.offset)) < ($1.element.zIndex ?? Double($1.offset))
        }.map(\.element)
        let candidates = Set((filteredPage(page, settings: settings).elements ?? []).map(\.id))
        return ordered.enumerated().compactMap { index, item in
            guard candidates.contains(item.id), item.kind != .highlight, item.visibleBounds.intersects(path.bounds) else { return nil }
            var visible = item.visiblePath.intersection(path.cgPath)
            for cover in ordered.dropFirst(index + 1) where cover.kind == .stickyNote {
                visible = visible.subtracting(cover.visiblePath)
            }
            return visible.isEmpty ? nil : item
        }
    }

    static func selectedInk(_ drawing: InkDrawing, inside path: UIBezierPath) -> InkDrawing {
        InkDrawing(strokes: drawing.strokes.filter { contains($0, inside: path) })
    }
    static func contains(_ stroke: InkStroke, inside path: UIBezierPath) -> Bool {
        guard stroke.renderBounds.intersects(path.bounds) else { return false }
        // Test in stroke space: transforming the lasso is far cheaper than copying the stroke's whole path.
        var inverse = stroke.transform.inverted()
        guard let local = path.cgPath.copy(using: &inverse) else { return false }
        return stroke.paintedPath.intersects(local, using: path.usesEvenOddFillRule ? .evenOdd : .winding)
    }
    static func copyInk(_ drawing: InkDrawing) throws {
        guard !drawing.strokes.isEmpty else { throw CocoaError(.validationMissingMandatoryProperty) }
        let data = try drawing.encodedData()
        guard data.count <= maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        UIPasteboard.general.setItems([[inkType: data]], options: [.localOnly: true])
    }
    /// `centered`: the point is where a finger landed, so the content is centred on it instead of hanging from it.
    static func decodeInk(_ data: Data, at point: CGPoint, pageSize: CGSize, centered: Bool = false) throws -> InkDrawing {
        guard data.count <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        let drawing = try InkDrawing(data: data)
        let bounds = drawing.bounds
        guard !drawing.strokes.isEmpty, drawing.strokes.count <= 10_000,
              bounds.width.isFinite, bounds.height.isFinite, bounds.minX.isFinite, bounds.minY.isFinite,
              bounds.width > 0, bounds.height > 0, pageSize.width > 0, pageSize.height > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let scale = min(1, pageSize.width / bounds.width, pageSize.height / bounds.height)
        let x = min(max(0, point.x - (centered ? bounds.width * scale / 2 : 0)), max(0, pageSize.width - bounds.width * scale))
        let y = min(max(0, point.y - (centered ? bounds.height * scale / 2 : 0)), max(0, pageSize.height - bounds.height * scale))
        var pasted = drawing.transformed(using: CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: x - bounds.minX * scale, ty: y - bounds.minY * scale))
        for index in pasted.strokes.indices { pasted.strokes[index].id = UUID() }
        return pasted
    }
}


extension DocumentClipboard {
    struct Payload: Codable {
        var version = 1
        var ink: Data
        var elements: [PageElement]
        var resources: [String: Data]
    }
    static func payload(page: NotePage, drawing: InkDrawing, path: UIBezierPath, settings: EditorToolSettings, resources: [String: Data]) throws -> Payload {
        let selected = SelectionMoveSnapshot(page: page, drawing: drawing, path: path, settings: settings)
        guard !selected.isEmpty else { throw CocoaError(.validationMissingMandatoryProperty) }
        let names = Set(selected.elements.compactMap(\.resource))
        guard names.allSatisfy({ resources[$0] != nil }) else { throw CocoaError(.fileNoSuchFile) }
        var ink = selected.ink
        for index in ink.strokes.indices where ink.strokes[index].parentID.map({ !selected.elementIDs.contains($0) }) == true { ink.strokes[index].parentID = nil }
        let elements = selected.elements.map { source -> PageElement in
            var item = source
            if item.parentID.map({ !selected.elementIDs.contains($0) }) == true { item.parentID = nil }
            return item
        }
        return Payload(ink: try ink.encodedData(), elements: elements, resources: resources.filter { names.contains($0.key) })
    }
    static func encode(_ payload: Payload) throws -> Data {
        let data = try JSONEncoder().encode(payload)
        guard data.count <= maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        return data
    }
    static func decode(_ data: Data, on page: NotePage, at point: CGPoint, centered: Bool = false) throws -> (InkDrawing, [PageElement], [String: Data]) {
        guard data.count <= maximumBytes, point.x.isFinite, point.y.isFinite else { throw CocoaError(.fileReadTooLarge) }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard payload.version == 1, payload.elements.count <= 10_000,
              payload.resources.keys.allSatisfy(NotebookArchive.safeResource) else { throw CocoaError(.fileReadCorruptFile) }
        var ink = try InkDrawing(data: payload.ink)
        var validationPage = page; validationPage.elements = []; validationPage.width = 20_000; validationPage.height = 20_000
        _ = try DocumentAction(pageID: page.id, kind: .setElements, elements: payload.elements).applying(to: validationPage)
        guard payload.elements.allSatisfy({ $0.resource == nil || payload.resources[$0.resource!] != nil }) else { throw CocoaError(.fileReadCorruptFile) }
        var bounds = ink.bounds
        for item in payload.elements { bounds = bounds.union(item.visibleBounds) }
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let size = PageRenderer.size(page)
        let scale = min(1, size.width / bounds.width, size.height / bounds.height)
        let x = min(max(0, point.x - (centered ? bounds.width * scale / 2 : 0)), max(0, size.width - bounds.width * scale))
        let y = min(max(0, point.y - (centered ? bounds.height * scale / 2 : 0)), max(0, size.height - bounds.height * scale))
        let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: x - bounds.minX * scale, ty: y - bounds.minY * scale)
        var ids: [UUID: UUID] = [:]
        for item in payload.elements { ids[item.id] = UUID() }
        var names: [String: String] = [:], resources: [String: Data] = [:]
        for (name, data) in payload.resources {
            let replacement = UUID().uuidString + "." + URL(fileURLWithPath: name).pathExtension
            names[name] = replacement; resources[replacement] = data
        }
        let elements = payload.elements.map { source in
            var item = source
            item.id = ids[source.id]!
            item.parentID = source.parentID.flatMap { ids[$0] }
            item.x = item.x * scale + transform.tx; item.y = item.y * scale + transform.ty
            item.width *= scale; item.height *= scale
            item.resource = item.resource.flatMap { names[$0] }
            return item
        }
        ink = ink.transformed(using: transform)
        for index in ink.strokes.indices {
            ink.strokes[index].id = UUID()
            ink.strokes[index].parentID = ink.strokes[index].parentID.flatMap { ids[$0] }
        }
        return (ink, elements, resources)
    }
}
