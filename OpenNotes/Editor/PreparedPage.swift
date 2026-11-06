import UIKit

struct PreparedPage {
    let drawing: InkDrawing
    let background: Data?
    let resources: [String: Data]
    let artwork: PageArtwork

    static func load(_ page: NotePage, disk: DiskStore, reusing artwork: PageArtwork? = nil) async throws -> PreparedPage {
        let end = Perf.begin("page.prepare"); defer { end() }
        guard let bytes = try await disk.read(page.drawingResourceID) else { throw CocoaError(.fileNoSuchFile) }
        let background: Data?
        if let name = page.backgroundID { background = try await disk.read(name) } else { background = nil }
        var resources: [String: Data] = [:]
        for item in page.elements ?? [] {
            try Task.checkCancellation()
            if let name = item.resource { resources[name] = try await disk.read(name) }
        }
        let work = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let assets: PageArtwork
            if let artwork, artwork.data == background, artwork.resources == resources { assets = artwork }
            else { assets = PageArtwork(page: page, data: background, resources: resources) }
            let result = PreparedPage(drawing: try InkDrawing(data: bytes), background: background, resources: resources, artwork: assets)
            try Task.checkCancellation()
            return result
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
}
