import UIKit

struct StickyInkOcclusion {
    private let notes: [(id: UUID, path: CGPath, bounds: CGRect)]
    private let elementsByID: [UUID: PageElement]

    init(_ elements: [PageElement]) {
        let lookup = elements.reduce(into: [UUID: PageElement]()) { $0[$1.id] = $1 }
        elementsByID = lookup
        notes = elements.enumerated().sorted {
            ($0.element.zIndex ?? Double($0.offset)) < ($1.element.zIndex ?? Double($1.offset))
        }.compactMap { _, element in
            guard element.kind == .stickyNote else { return nil }
            var path = element.visiblePath
            var parent = element.parentID, visited: Set<UUID> = [element.id]
            while let id = parent, visited.insert(id).inserted, let ancestor = lookup[id] {
                if ancestor.kind == .stickyNote && ancestor.collapsed == true { return nil }
                if ancestor.kind == .stickyNote { path = path.intersection(ancestor.visiblePath) }
                parent = ancestor.parentID
            }
            return (element.id, path, path.boundingBoxOfPath)
        }
    }

    private func ancestors(_ stroke: InkStroke) -> [(id: UUID, path: CGPath, bounds: CGRect)] {
        var result: [(id: UUID, path: CGPath, bounds: CGRect)] = []
        var parent = stroke.parentID, visited: Set<UUID> = []
        while let id = parent, visited.insert(id).inserted, let element = elementsByID[id] {
            if let note = notes.first(where: { $0.id == id }) { result.append(note) }
            parent = element.parentID
        }
        return result
    }

    private func covers(_ stroke: InkStroke, ancestors: [(id: UUID, path: CGPath, bounds: CGRect)]) -> [(id: UUID, path: CGPath, bounds: CGRect)] {
        let start = ancestors.first.flatMap { parent in notes.firstIndex { $0.id == parent.id } }.map { $0 + 1 } ?? 0
        let parentIDs = Set(ancestors.map(\.id))
        let box = stroke.renderBounds   // hoisted: it was recomputed for every note
        return Array(notes.dropFirst(start)).filter { !parentIDs.contains($0.id) && $0.bounds.intersects(box) }
    }

    func mask(for stroke: InkStroke, worldCoordinates: Bool = false) -> CAShapeLayer? {
        let parents = ancestors(stroke), covers = covers(stroke, ancestors: parents)
        guard !parents.isEmpty || !covers.isEmpty else { return nil }
        let bounds = worldCoordinates ? stroke.renderBounds : stroke.paintedPath.boundingBoxOfPath
        var remaining = CGPath(rect: bounds, transform: nil)
        var inverse = worldCoordinates ? CGAffineTransform.identity : stroke.transform.inverted()
        for parent in parents { if let path = parent.path.copy(using: &inverse) { remaining = remaining.intersection(path) } }
        for note in covers {
            if let path = note.path.copy(using: &inverse) { remaining = remaining.subtracting(path) }
        }
        let mask = CAShapeLayer()
        mask.bounds = bounds
        mask.position = CGPoint(x: bounds.midX, y: bounds.midY)
        mask.path = remaining
        mask.fillColor = UIColor.black.cgColor
        return mask
    }

    /// Same rule as `EditorSession.attachingInk`: the topmost open, unlocked note under the first sample owns the stroke.
    func previewMask(startingAt point: CGPoint, in rect: CGRect) -> CAShapeLayer? {
        guard !notes.isEmpty else { return nil }
        let parent = notes.lastIndex { note in
            guard let element = elementsByID[note.id], element.collapsed != true, element.isLocked != true else { return false }
            return note.path.contains(point)
        }
        var remaining = parent.map { notes[$0].path } ?? CGPath(rect: rect, transform: nil)
        for note in notes.dropFirst(parent.map { $0 + 1 } ?? 0) where note.bounds.intersects(remaining.boundingBoxOfPath) {
            remaining = remaining.subtracting(note.path)
        }
        let mask = CAShapeLayer()
        mask.frame = rect
        mask.path = remaining
        mask.fillColor = UIColor.black.cgColor
        return mask
    }

    func visible(_ stroke: InkStroke) -> InkStroke? {
        let parents = ancestors(stroke), covers = covers(stroke, ancestors: parents)
        guard !parents.isEmpty || !covers.isEmpty else { return stroke }
        var remaining = stroke.paintedPath
        var inverse = stroke.transform.inverted()
        for parent in parents { if let path = parent.path.copy(using: &inverse) { remaining = remaining.intersection(path) } }
        for note in covers {
            if let path = note.path.copy(using: &inverse) { remaining = remaining.subtracting(path) }
        }
        guard !remaining.isEmpty else { return nil }
        var result = stroke
        result.vectorOutline = InkVectorPath(remaining)
        return result
    }
}

extension InkDrawing {
    // The document paper stays white even when the surrounding interface is dark.
    func paperImage(from rect: CGRect, scale: CGFloat) -> UIImage {
        var rendered: UIImage!
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            rendered = image(from: rect, scale: scale)
        }
        return rendered
    }
}
