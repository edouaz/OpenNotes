import UIKit

extension NotePage {
    var collapsedContentParents: Set<UUID> {
        var hidden = Set((elements ?? []).filter { $0.kind == .stickyNote && $0.collapsed == true }.map(\.id))
        var count = 0
        while count != hidden.count {
            count = hidden.count
            for item in elements ?? [] where item.parentID.map({ hidden.contains($0) }) == true { hidden.insert(item.id) }
        }
        return hidden
    }
}

extension InkDrawing {
    func visible(on page: NotePage) -> InkDrawing {
        let hidden = page.collapsedContentParents
        let occlusion = StickyInkOcclusion(page.elements ?? [])
        return InkDrawing(strokes: strokes.filter { $0.parentID.map { !hidden.contains($0) } ?? true }.compactMap { occlusion.visible($0) })
    }
}

extension InkStroke {
    func clipped(to note: PageElement) -> InkStroke? {
        var inverse = transform.inverted()
        guard let boundary = note.visiblePath.copy(using: &inverse) else { return nil }
        let clipped = paintedPath.intersection(boundary)
        guard !clipped.isEmpty else { return nil }
        var result = self
        result.vectorOutline = InkVectorPath(clipped)
        return result
    }
}

@MainActor
extension EditorSession {
    func attachingInk(_ replacement: InkDrawing) -> InkDrawing {
        let existing = Set(drawing.strokes.map(\.id))
        let notes = (page?.elements ?? []).enumerated().sorted {
            ($0.element.zIndex ?? Double($0.offset)) < ($1.element.zIndex ?? Double($1.offset))
        }.map(\.element).filter { $0.kind == .stickyNote && $0.collapsed != true && $0.isLocked != true }
        return InkDrawing(strokes: replacement.strokes.map { source in
            guard !existing.contains(source.id), source.parentID == nil, let first = source.path.first else { return source }
            var stroke = source
            for note in notes.reversed() {
                let point = first.location.applying(source.transform)
                if note.visiblePath.contains(point) {
                    stroke.parentID = note.id
                    break
                }
            }
            return stroke
        })
    }

    func reconcileStickyInk(_ replacement: InkDrawing, previous: [PageElement], updated: [PageElement]) -> InkDrawing {
        let oldNotes = Dictionary(uniqueKeysWithValues: previous.filter { $0.kind == .stickyNote }.map { ($0.id, $0) })
        let notes = Dictionary(uniqueKeysWithValues: updated.filter { $0.kind == .stickyNote }.map { ($0.id, $0) })
        let originals = Dictionary(uniqueKeysWithValues: drawing.strokes.map { ($0.id, $0) })
        return InkDrawing(strokes: replacement.strokes.compactMap { source in
            guard let parentID = source.parentID, let old = oldNotes[parentID] else { return source }
            guard let new = notes[parentID] else { return nil }
            if old.x == new.x && old.y == new.y && old.width == new.width && old.height == new.height && old.rotation == new.rotation { return source }
            guard let original = originals[source.id], original.transform == source.transform,
                  original.path.controlPoints == source.path.controlPoints else { return source }
            let transform = stickyTransform(old).inverted()
                .concatenating(CGAffineTransform(translationX: -old.x, y: -old.y))
                .concatenating(CGAffineTransform(translationX: new.x, y: new.y))
                .concatenating(stickyTransform(new))
            var stroke = source
            stroke.transform = source.transform.concatenating(transform)
            return stroke
        })
    }

    func reconcileStickyElements(_ replacement: [PageElement], previous: [PageElement], attaching: Bool = false) -> [PageElement] {
        let originals = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let oldNotes = Dictionary(uniqueKeysWithValues: previous.filter { $0.kind == .stickyNote }.map { ($0.id, $0) })
        let notes = Dictionary(uniqueKeysWithValues: replacement.filter { $0.kind == .stickyNote }.map { ($0.id, $0) })
        return replacement.compactMap { source in
            var item = source
            if let parent = source.parentID, let old = oldNotes[parent] {
                guard let new = notes[parent] else { return nil }
                if old.x == new.x && old.y == new.y && old.width == new.width && old.height == new.height && (old.rotation ?? 0) == (new.rotation ?? 0) { return source }
                if originals[source.id] == source {
                    let transform = stickyTransform(old).inverted()
                        .concatenating(CGAffineTransform(translationX: -old.x, y: -old.y))
                        .concatenating(CGAffineTransform(translationX: new.x, y: new.y))
                        .concatenating(stickyTransform(new))
                    let center = CGPoint(x: source.x + source.width / 2, y: source.y + source.height / 2).applying(transform)
                    item.x = center.x - item.width / 2; item.y = center.y - item.height / 2
                    item.rotation = (source.rotation ?? 0) + (new.rotation ?? 0) - (old.rotation ?? 0)
                }
            } else if attaching, item.parentID == nil, item.kind != .stickyNote, originals[item.id] != item {
                let ordered = replacement.enumerated().sorted {
                    ($0.element.zIndex ?? Double($0.offset)) > ($1.element.zIndex ?? Double($1.offset))
                }.map(\.element)
                for note in ordered where note.kind == .stickyNote && note.collapsed != true && note.isLocked != true {
                    let center = CGPoint(x: item.x + item.width / 2, y: item.y + item.height / 2)
                    if note.visiblePath.contains(center) { item.parentID = note.id; break }
                }
            }
            return item
        }
    }

    private func stickyTransform(_ note: PageElement) -> CGAffineTransform {
        let center = CGPoint(x: note.x + note.width / 2, y: note.y + note.height / 2)
        let angle = note.rotation ?? 0, c = cos(angle), s = sin(angle)
        return CGAffineTransform(a: c, b: s, c: -s, d: c,
            tx: center.x - c * center.x + s * center.y,
            ty: center.y - s * center.x - c * center.y)
    }
}
