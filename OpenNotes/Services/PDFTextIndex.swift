import PDFKit

// PDFKit objects stay inside the task that created them; only value data crosses actors.
enum PDFTextIndex {
    static func extract(_ data: Data) throws -> [PageTextContent] {
        guard let document = PDFDocument(data: data), !document.isLocked else { throw CocoaError(.fileReadCorruptFile) }
        return (0..<document.pageCount).map { index in
            guard let page = document.page(at: index) else {
                return PageTextContent(source: .pdf, status: .needsRecognition, text: "", blocks: [])
            }
            let size = pageSize(page)
            let transform = drawingTransform(page, size: size)
            let text = page.string ?? ""
            let selection = page.selection(for: page.bounds(for: .cropBox))
            let blocks = (selection?.selectionsByLine() ?? []).compactMap { line -> PageTextContent.Block? in
                guard let text = line.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                let rect = line.bounds(for: page).applying(transform)
                guard !rect.isNull, rect.width.isFinite, rect.height.isFinite else { return nil }
                return .init(text: text, x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height, confidence: nil)
            }
            return PageTextContent(source: .pdf, status: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .needsRecognition : .available, text: text, blocks: blocks, engine: "PDFKit")
        }
    }

    /// Precise match bounds on one PDF page, in page coordinates (top-left origin), matching PageRenderer's cropBox aspect-fit.
    static func matchRects(_ page: PDFPage, query: String, size: CGSize, limit: Int = 200) -> [CGRect] {
        guard !query.isEmpty, let text = page.string as NSString? else { return [] }
        let transform = drawingTransform(page, size: size)
        var rects: [CGRect] = []
        var range = NSRange(location: 0, length: text.length)
        while rects.count < limit {
            let found = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: range)
            guard found.location != NSNotFound, found.length > 0 else { break }
            for line in page.selection(for: found)?.selectionsByLine() ?? [] {
                let rect = line.bounds(for: page).applying(transform)
                guard !rect.isNull, rect.width.isFinite, rect.height.isFinite else { continue }
                rects.append(CGRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height))
            }
            range = NSRange(location: found.upperBound, length: text.length - found.upperBound)
        }
        return rects
    }
    private static func pageSize(_ page: PDFPage) -> CGSize {
        let size = page.bounds(for: .cropBox).size
        return abs(page.rotation) % 180 == 90 ? CGSize(width: size.height, height: size.width) : size
    }
    // Same transform PageRenderer concatenates after its y flip, so PDF y-up maps to page y-down via size.height - maxY.
    private static func drawingTransform(_ page: PDFPage, size: CGSize) -> CGAffineTransform {
        page.pageRef?.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true) ?? .identity
    }
}

/// Keeps the parsed PDFDocument between search-result taps; the document never leaves this actor.
actor PDFMatchFinder {
    static let shared = PDFMatchFinder()
    // ponytail: one cached document (a notebook is normally one imported PDF); key by resource name per document if notebooks mix PDFs.
    private var cached: (name: String, document: PDFDocument)?
    func rects(resource name: String, disk: DiskStore, pageIndex: Int, query: String, size: CGSize) async -> [CGRect] {
        if cached?.name != name {
            guard let data = try? await disk.read(name), let document = PDFDocument(data: data), !document.isLocked else { return [] }
            cached = (name, document)
        }
        guard let page = cached?.document.page(at: pageIndex) else { return [] }
        return PDFTextIndex.matchRects(page, query: query, size: size)
    }
}
