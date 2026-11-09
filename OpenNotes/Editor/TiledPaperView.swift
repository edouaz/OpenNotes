import UIKit
import QuartzCore

final class TiledPaperView: UIView {
    private var tiles = ImmediatePaperTiles()
    private let renderer = PaperTileRenderer()
    private(set) var invalidationCount = 0
    private var previewTask: Task<Void, Never>?
    private var previewGeneration = UUID()
    private var previewPageID: UUID?
    // Tiles redrawn since the last invalidation, in layer coordinates, and the region they must cover.
    private var drawnGeneration = 0
    private var drawnTiles: [CGRect] = []
    private var dirtyRegion: CGRect?
    private var settleActions: [() -> Void] = []
    private var settleDeadline: DispatchWorkItem?
    /// Called once the paper of a newly installed page shows its own content.
    var onPageReady: ((UUID) -> Void)?
    deinit { previewTask?.cancel() }
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .white
        installTiles()
        renderer.drawn = { [weak self] rect, generation in
            DispatchQueue.main.async { self?.tileDrawn(rect, generation: generation) }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func installTiles() {
        let fresh = ImmediatePaperTiles()
        fresh.delegate = renderer
        fresh.tileSize = CGSize(width: 512, height: 512)
        fresh.levelsOfDetail = 4
        fresh.levelsOfDetailBias = AppPreferences.sharpZoom ? 3 : 2   // read when a page is installed
        fresh.contentsScale = UIScreen.main.scale
        fresh.needsDisplayOnBoundsChange = true
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fresh.frame = bounds
        tiles.delegate = nil; tiles.removeFromSuperlayer()
        layer.addSublayer(fresh)
        CATransaction.commit()
        tiles = fresh
    }
    func configure(page: NotePage, artwork: PageArtwork?, drawing: InkDrawing? = nil) {
        guard let artwork else { return }
        let newPage = previewPageID != page.id
        let change = renderer.configure(page: page, artwork: artwork, drawing: drawing)
        if newPage {
            // A fresh tiled layer: the old one kept the previous page's tiles (a PDF page showed through a new blank page).
            previewPageID = page.id
            layer.contents = nil
            installTiles()
        }
        guard newPage || change != .none else { return }
        invalidationCount += 1
        drawnGeneration = renderer.generation; drawnTiles = []
        let size = PageRenderer.size(page)
        let scale = CGSize(width: bounds.width / max(1, size.width), height: bounds.height / max(1, size.height))
        if !newPage, case .rect(let rect) = change {
            let region = CGRect(x: rect.minX * scale.width, y: rect.minY * scale.height, width: rect.width * scale.width, height: rect.height * scale.height)
            dirtyRegion = (dirtyRegion ?? .null).union(region)
            tiles.setNeedsDisplay(region)
        } else {
            dirtyRegion = bounds
            if !newPage { tiles.setNeedsDisplay() }
        }
        armSettleDeadline()
        previewTask?.cancel()
        let generation = UUID(); previewGeneration = generation
        // A bounded preview stays under the tiles for zooming; same-page edits refresh it lazily, at low priority.
        previewTask = Task { [weak self] in
            if !newPage { do { try await Task.sleep(nanoseconds: AppPreferences.batterySaver ? 3_000_000_000 : 600_000_000) } catch { return } }
            let work = Task.detached(priority: newPage ? .userInitiated : .utility) {
                guard !Task.isCancelled else { return nil as CGImage? }
                return PageRenderer.image(page, data: artwork.data, drawing: drawing, resources: artwork.resources,
                    pdfPage: artwork.pdfPage, images: artwork.images, scale: min(1, 1400 / max(size.width, size.height))).cgImage
            }
            let image = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled, let self, self.previewGeneration == generation else { return }
            self.layer.contents = image
            if newPage { self.onPageReady?(page.id) }
        }
    }
    /// Runs `action` once the visible tiles show the latest content (or soon, when nothing is being redrawn).
    /// Overlays that preview an edit wait for this, so the old content never flashes for a frame.
    func whenDrawn(_ action: @escaping () -> Void) {
        settleActions.append(action)
        if dirtyRegion == nil {
            // The edit may reach the paper on SwiftUI's next update: give it a moment to invalidate first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self, self.dirtyRegion == nil else { return }
                self.settle()
            }
        }
        armSettleDeadline()
    }
    private func armSettleDeadline() {
        settleDeadline?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.settle() }
        settleDeadline = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }
    private func tileDrawn(_ rect: CGRect, generation: Int) {
        guard generation == drawnGeneration, let dirty = dirtyRegion else { return }
        drawnTiles.append(rect)
        let visible = superview.map { convert($0.bounds, from: $0) }.map { $0.intersection(bounds) } ?? bounds
        let region = dirty.intersection(visible).insetBy(dx: 1, dy: 1)
        guard !region.isNull, !region.isEmpty else { settle(); return }
        // Sample the region: settled when every sample lies in a tile redrawn for this generation.
        let steps = 6
        for i in 0...steps {
            for j in 0...steps {
                let point = CGPoint(x: region.minX + region.width * CGFloat(i) / CGFloat(steps), y: region.minY + region.height * CGFloat(j) / CGFloat(steps))
                if !drawnTiles.contains(where: { $0.contains(point) }) { return }
            }
        }
        settle()
    }
    private func settle() {
        dirtyRegion = nil; drawnTiles = []
        settleDeadline?.cancel(); settleDeadline = nil
        let actions = settleActions; settleActions = []
        actions.forEach { $0() }
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
    enum Change: Equatable { case none, full, rect(CGRect) }
    private let lock = NSLock()
    private var content: (NotePage, PageArtwork, InkDrawing?, Data?, Int)?
    private var counter = 0
    var drawn: ((CGRect, Int) -> Void)?
    var generation: Int { lock.lock(); defer { lock.unlock() }; return counter }
    func configure(page: NotePage, artwork: PageArtwork, drawing: InkDrawing?) -> Change {
        let drawingData = drawing?.dataRepresentation()
        lock.lock(); defer { lock.unlock() }
        let change: Change
        if let (old, assets, _, previousDrawingData, _) = content {
            if PageRenderer.size(old) != PageRenderer.size(page) || old.template != page.template ||
                old.backgroundID != page.backgroundID || old.pdfIndex != page.pdfIndex || old.text != page.text ||
                (assets !== artwork && assets.data != artwork.data) || previousDrawingData != drawingData || old.id != page.id {
                change = .full
            } else if old.elements != page.elements || (assets !== artwork && assets.resources != artwork.resources) {
                change = Self.changedRect(old.elements ?? [], page.elements ?? []).map { .rect($0) } ?? .full
            } else { change = .none }
        } else { change = .full }
        if change != .none { counter += 1 }
        content = (page, artwork, drawing, drawingData, counter)
        return change
    }
    /// Union of the bounds of every added, removed or edited element, with room for shadows and rotation.
    /// nil when a change can reach beyond its own bounds (collapsing a note hides or shows its children).
    static func changedRect(_ old: [PageElement], _ new: [PageElement]) -> CGRect? {
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(new.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if old.map(\.id) != new.map(\.id), Set(before.keys) == Set(after.keys) { return nil }   // reordered: stacking changed
        var rect = CGRect.null
        func add(_ item: PageElement) {
            let box = CGRect(x: item.x, y: item.y, width: item.width, height: item.height)
            let reach = item.rotation.map { $0 == 0 ? 0 : hypot(box.width, box.height) / 2 } ?? 0
            rect = rect.union(box.insetBy(dx: -24 - reach, dy: -24 - reach))
        }
        for id in Set(before.keys).union(after.keys) {
            let a = before[id], b = after[id]
            guard a != b else { continue }
            if a?.collapsed != b?.collapsed && (a?.kind == .stickyNote || b?.kind == .stickyNote) { return nil }
            a.map(add); b.map(add)
        }
        return rect.isNull ? nil : rect
    }
    func draw(_ layer: CALayer, in context: CGContext) {
        let tile = context.boundingBoxOfClipPath
        lock.lock(); let snapshot = content; lock.unlock()
        guard let snapshot else { return }
        context.saveGState()
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext(); context.restoreGState(); drawn?(tile, snapshot.4) }
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
