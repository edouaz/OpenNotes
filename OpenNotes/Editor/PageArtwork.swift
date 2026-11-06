import UIKit
import PDFKit

// Immutable assets prepared away from the UI, then shared by visible rendering tiles.
final class PageArtwork {
    let data: Data?
    let resources: [String: Data]
    let pdfPage: CGPDFPage?
    let images: [String: UIImage]
    init(page: NotePage, data: Data?, resources: [String: Data]) {
        let end = Perf.begin("pdf.open"); defer { end() }
        self.data = data; self.resources = resources
        if let data, let index = page.pdfIndex, let provider = CGDataProvider(data: data as CFData) {
            pdfPage = CGPDFDocument(provider)?.page(at: index + 1)
        } else { pdfPage = nil }
        var images: [String: UIImage] = [:]
        if page.pdfIndex == nil, let data { images["background"] = UIImage(data: data) }
        for (name, bytes) in resources { images[name] = UIImage(data: bytes) }
        self.images = images
    }
}
