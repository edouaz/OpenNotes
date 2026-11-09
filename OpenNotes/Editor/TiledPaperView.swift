import UIKit
import QuartzCore

final class TiledPaperView: UIView {
    private let tiles = ImmediatePaperTiles()
    private let renderer = PaperTileRenderer()
    private(set) var invalidationCount = 0
    private var previewTask: Task<Void, Never>?
    private var previewGeneration = UUID()
    private var previewPageID: UUID?
    deinit { previewTask?.cancel() }
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .white
        tiles.delegate = renderer
        tiles.tileSize = CGSize(width: 512, height: 512)
        tiles.levelsOfDetail = 4
        tiles.levelsOfDetailBias = AppPreferences.sharpZoom ? 3 : 2
        tiles.contentsScale = UIScreen.main.scale
        tiles.needsDisplayOnBoundsChange = true
        layer.addSublayer(tiles)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(page: NotePage, artwork: PageArtwork?, drawing: InkDrawing? = nil) {
        guard let artwork else { return }
        if renderer.configure(page: page, artwork: artwork, drawing: drawing) {
            invalidationCount += 1; tiles.setNeedsDisplay()
            previewTask?.cancel()
            let generation = UUID(); previewGeneration = generation
            let newPage = previewPageID != page.id
            previewPageID = page.id
            if newPage { layer.contents = nil }
            // A bounded preview stays visible while asynchronous tiles are being prepared.
            previewTask = Task { [weak self] in
                // Coalesce drawing updates; never render a full preview for every live sample.
                if !newPage { do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return } }
                let work = Task.detached(priority: .userInitiated) {
                    guard !Task.isCancelled else { return nil as CGImage? }
                    let size = PageRenderer.size(page)
                    return PageRenderer.image(page, data: artwork.data, drawing: drawing, resources: artwork.resources,
                        pdfPage: artwork.pdfPage, images: artwork.images, scale: min(1, 1400 / max(size.width, size.height))).cgImage
                }
                let image = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
                guard !Task.isCancelled, let self, self.previewGeneration == generation else { return }
                self.layer.contents = image
            }
        }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        tiles.frame = bounds
        CATransaction.commit()
    }
}

// Tile threads only read immutable artwork; they never draw or query a UIView.
private final class PaperTileRenderer: NSObject, CALayerDelegate {
    private let lock = NSLock()
    private var content: (NotePage, PageArtwork, InkDrawing?, Data?)?
    func configure(page: NotePage, artwork: PageArtwork, drawing: InkDrawing?) -> Bool {
        let drawingData = drawing?.dataRepresentation()
        lock.lock(); defer { lock.unlock() }
        let changed: Bool
        if let (old, assets, _, previousDrawingData) = content {
            changed = PageRenderer.size(old) != PageRenderer.size(page) || old.template != page.template ||
                old.backgroundID != page.backgroundID || old.pdfIndex != page.pdfIndex || old.text != page.text || old.elements != page.elements ||
                (assets !== artwork && (assets.data != artwork.data || assets.resources != artwork.resources)) || previousDrawingData != drawingData
        } else { changed = true }
        content = (page, artwork, drawing, drawingData)
        return changed
    }
    func draw(_ layer: CALayer, in context: CGContext) {
        lock.lock(); let snapshot = content; lock.unlock()
        guard let snapshot else { return }
        context.saveGState()
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext(); context.restoreGState() }
        let size = PageRenderer.size(snapshot.0)
        context.scaleBy(x: layer.bounds.width / size.width, y: layer.bounds.height / size.height)
        if let drawing = snapshot.2 {
            PageRenderer.composite(snapshot.0, data: snapshot.1.data, drawing: drawing, resources: snapshot.1.resources,
                context: context, pdfPage: snapshot.1.pdfPage, images: snapshot.1.images,
                inkScale: max(1, abs(context.ctm.a)), inkRect: context.boundingBoxOfClipPath)
        } else {
            PageRenderer.background(snapshot.0, data: snapshot.1.data, resources: snapshot.1.resources, context: context, pdfPage: snapshot.1.pdfPage, images: snapshot.1.images)
        }
    }
}

// A tile becoming sharper should not flash or fade during a pinch.
private final class ImmediatePaperTiles: CATiledLayer {
    override class func fadeDuration() -> CFTimeInterval { 0 }
}
