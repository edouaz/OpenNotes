import Foundation

struct DocumentAction: Codable, Sendable {
    enum Kind: String, Codable { case setBookmark, upsertElement, removeElement, setElements }
    var pageID: UUID
    var kind: Kind
    var bookmark: Bool?
    var element: PageElement?
    var elementID: UUID?
    var expectedRevision: Int?
    var elements: [PageElement]?

    func applying(to original: NotePage) throws -> NotePage {
        guard original.id == pageID, expectedRevision == nil || expectedRevision == (original.revision ?? 0) else { throw CocoaError(.userCancelled) }
        var page = original
        switch kind {
        case .setBookmark:
            guard let bookmark else { throw CocoaError(.fileReadCorruptFile) }
            page.bookmark = bookmark
        case .upsertElement:
            guard let element, valid(element, on: page) else { throw CocoaError(.fileReadCorruptFile) }
            var elements = page.elements ?? []
            if let index = elements.firstIndex(where: { $0.id == element.id }) { elements[index] = element }
            else { elements.append(element) }
            page.elements = elements
        case .removeElement:
            guard let elementID else { throw CocoaError(.fileReadCorruptFile) }
            var removed: Set<UUID> = [elementID]
            var previousCount = 0
            while previousCount != removed.count {
                previousCount = removed.count
                for item in page.elements ?? [] where item.parentID.map({ removed.contains($0) }) == true { removed.insert(item.id) }
            }
            page.elements?.removeAll { removed.contains($0.id) }
        case .setElements:
            guard let elements, Set(elements.map(\.id)).count == elements.count,
                  elements.allSatisfy({ valid($0, on: page) }) else { throw CocoaError(.fileReadCorruptFile) }
            page.elements = elements
        }
        guard Self.validHierarchy(page.elements ?? []) else { throw CocoaError(.fileReadCorruptFile) }
        return page
    }

    static func validHierarchy(_ elements: [PageElement]) -> Bool {
        guard Set(elements.map(\.id)).count == elements.count else { return false }
        let parents = Dictionary(uniqueKeysWithValues: elements.map { ($0.id, $0.parentID) })
        var checked: Set<UUID> = []
        for item in elements {
            var current: UUID? = item.id
            var branch: Set<UUID> = []
            while let id = current, !checked.contains(id) {
                guard branch.insert(id).inserted else { return false }
                current = parents[id] ?? nil
            }
            checked.formUnion(branch)
        }
        return true
    }

    func valid(_ element: PageElement, on page: NotePage) -> Bool {
        element.parentID != element.id &&
        (element.rotation.map { $0.isFinite && abs($0) <= 1_000_000 } ?? true) &&
        (element.zIndex.map { $0.isFinite && abs($0) <= 1_000_000 } ?? true) &&
        (element.richTextRTF.map { RichTextDocument.isValid($0, text: element.text) } ?? true) &&
        element.x.isFinite && element.y.isFinite && element.width.isFinite && element.height.isFinite &&
        element.x >= 0 && element.y >= 0 && element.width > 0 && element.height > 0 &&
        element.x + element.width <= (page.width ?? 794) + 0.01 &&
        element.y + element.height <= (page.height ?? 1123) + 0.01 &&
        (element.stickyCornerRadius.map { $0.isFinite && (0...24).contains($0) } ?? true) &&
        (element.stickyOpacity.map { $0.isFinite && (0...1).contains($0) } ?? true) &&
        (element.stickyShadow.map { $0.isFinite && (0...0.3).contains($0) } ?? true) &&
        (element.strokeWidth.map { $0.isFinite && (0.5...32).contains($0) } ?? true) &&
        [element.strokeColorHex, element.fillColorHex].compactMap { $0 }.allSatisfy { color in
            color.count == 7 && color.first == "#" && color.dropFirst().allSatisfy(\.isHexDigit)
        } &&
        (element.textFontSize.map { $0.isFinite && (8...96).contains($0) } ?? true) &&
        (element.textColorHex.map { $0.count == 7 && $0.first == "#" && $0.dropFirst().allSatisfy(\.isHexDigit) } ?? true) &&
        (element.kind != .image || element.resource != nil) &&
        (element.resource == nil || NotebookArchive.safeResource(element.resource!)) && element.text.count <= 100_000
    }
}
