import UIKit

enum PageSelectionAction { case preview, copyPhoto, copyInk, enlarge, shrink, deleteContent, copySelection, cutSelection, duplicateSelection, lockSelection, collapseSelection, bringFront, sendBack, editText, recolorSelection, formatText }

final class PageSelectionView: UIView, UIEditMenuInteractionDelegate, UIGestureRecognizerDelegate {
    var selected: ((CGRect, UIBezierPath, PageSelectionAction) -> Void)?
    var immediate = false
    /// Manipulation mode: handles are shown only after the user asks for them (long press or menu) and never persist.
    var showsResizeHandles = false { didSet { updateHandles() } }
    var manipulationChanged: ((Bool) -> Void)?
    var shape = EditorToolSettings.LassoShape.freeform
    var moveBegan: ((UIBezierPath) -> Void)?
    var moveChanged: ((CGPoint) -> CGPoint)?
    var moveCancelled: (() -> Void)?
    var moved: ((UIBezierPath, CGPoint) -> Void)?
    var pasteMenuRequested: ((CGPoint) -> Void)?
    var pasteRequested: ((CGPoint) -> Void)?
    var transformChanged: ((CGFloat, CGFloat, CGFloat, CGPoint) -> Void)?
    var transformCommitted: ((UIBezierPath, CGFloat, CGFloat, CGFloat, CGPoint) -> Void)?
    var allowsFreeResize: ((UIBezierPath) -> Bool)?
    var directSelection: ((CGPoint) -> UIBezierPath?)?
    /// A lasso was closed: the owner records which objects it contains, once.
    var selectionCompleted: ((UIBezierPath) -> Void)?
    /// The previous selection no longer exists (a new lasso started, or a tap cleared it).
    var selectionDiscarded: (() -> Void)?
    var menuActions: ((UIBezierPath) -> [UIMenuElement])?
    private var handles: [UIView] = []
    private var freeResizeAllowed = false
    // The eligibility check builds a full selection snapshot, so it runs only when handles are shown.
    private var freeResizeStale = false
    private var transformOrigin = UIBezierPath()
    private var transformStart = CGPoint.zero
    private var pendingScale: CGFloat = 1
    private var pendingRotation: CGFloat = 0
    private var pendingScaleY: CGFloat = 1
    private var transformAnchor = CGPoint.zero
    private var path = UIBezierPath()
    private var completed = false
    private var start = CGPoint.zero
    private var moving = false
    private var originalPath = UIBezierPath()
    private let outline = CAShapeLayer()
    private lazy var editMenu = UIEditMenuInteraction(delegate: self)
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
    private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
    private lazy var hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
    private var passesBodyTouches = false
    private var followed: (zoom: CGFloat, offset: CGPoint)?
    /// The selection lives in screen space while it is drawn, but it must stay glued to the page.
    /// Called on every scroll/zoom: re-projects every stored path from the previous viewport to the new one.
    func follow(zoom: CGFloat, offset: CGPoint) {
        defer { followed = (zoom, offset) }
        guard let old = followed, old.zoom > 0, zoom > 0, old.zoom != zoom || old.offset != offset else { return }
        let scale = zoom / old.zoom
        let move = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                     tx: old.offset.x * scale - offset.x, ty: old.offset.y * scale - offset.y)
        for stored in [path, originalPath, transformOrigin] { stored.apply(move) }
        start = start.applying(move); transformStart = transformStart.applying(move); transformAnchor = transformAnchor.applying(move)
        if !path.isEmpty { outline.path = path.cgPath }
        updateHandles()
    }
    var activeGestures: [UIGestureRecognizer] { [pan, tap, hold] }
    override var isUserInteractionEnabled: Bool {
        didSet { activeGestures.forEach { $0.isEnabled = isUserInteractionEnabled } }
    }
    func hostGestures(on host: UIView?, pencilOnly: Bool) {
        passesBodyTouches = pencilOnly
        pan.allowedTouchTypes = (pencilOnly ? [.pencil] : [.direct, .pencil] as [UITouch.TouchType]).map { NSNumber(value: $0.rawValue) }
        tap.allowedTouchTypes = pan.allowedTouchTypes
        for gesture in activeGestures {
            let target = host ?? self
            if gesture.view !== target { gesture.view?.removeGestureRecognizer(gesture); target.addGestureRecognizer(gesture) }
        }
    }
    func detachGestures() { activeGestures.forEach { $0.view?.removeGestureRecognizer($0) } }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !passesBodyTouches || touch.view?.isDescendant(of: self) != true
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return passesBodyTouches && hit === self ? nil : hit
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        outline.fillColor = UIColor.systemBlue.withAlphaComponent(0.12).cgColor
        outline.strokeColor = UIColor.systemBlue.cgColor; outline.lineWidth = 2; outline.lineDashPattern = [6, 4]
        layer.addSublayer(outline)
        pan.maximumNumberOfTouches = 1
        activeGestures.forEach { $0.delegate = self }
        addGestureRecognizer(pan)
        addGestureRecognizer(tap)
        for index in 0..<9 {
            let handle = UIView(); handle.tag = index
            let dot = UIView(frame: CGRect(x: 17, y: 17, width: 10, height: 10))
            dot.backgroundColor = index >= 5 ? .systemBlue : .white; dot.layer.borderColor = UIColor.systemBlue.cgColor; dot.layer.borderWidth = 2
            dot.layer.cornerRadius = index >= 4 ? 5 : 1
            dot.isUserInteractionEnabled = false; handle.addSubview(dot)
            handle.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(transformDragged(_:))))
            handle.accessibilityLabel = index == 4 ? "Rotate selection" : "Scale selection"
            handle.isHidden = true; addSubview(handle); handles.append(handle)
        }
        hold.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        addGestureRecognizer(hold); addInteraction(editMenu)
        isAccessibilityElement = true
        accessibilityLabel = "Area selection"
        accessibilityHint = "Outline an area, then move its contents or long press inside to copy strokes or capture an image."
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Enlarge selection") { [weak self] _ in self?.perform(.enlarge); return true },
            UIAccessibilityCustomAction(name: "Shrink selection") { [weak self] _ in self?.perform(.shrink); return true },
            UIAccessibilityCustomAction(name: "Delete selection") { [weak self] _ in self?.perform(.deleteContent); return true },
            UIAccessibilityCustomAction(name: "Copy image") { [weak self] _ in self?.perform(.copyPhoto); return true },
            UIAccessibilityCustomAction(name: "Copy strokes") { [weak self] _ in self?.perform(.copyInk); return true },
            UIAccessibilityCustomAction(name: "Share image") { [weak self] _ in self?.perform(.preview); return true }
        ]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func clearSelection() {
        completed = false; path = UIBezierPath(); outline.path = nil; editMenu.dismissMenu()
        showsResizeHandles = false; handles.forEach { $0.isHidden = true }
    }
    var selectionBounds: CGRect { path.bounds }
    func dismissMenu() { editMenu.dismissMenu() }
    /// Ends any drag in progress as well: its commit must not run against a document that just changed.
    func cancelInteraction() {
        moving = false
        activeGestures.forEach { $0.isEnabled = false; $0.isEnabled = true }
        clearSelection()
    }
    func enterManipulation() {
        guard completed, !immediate else { return }
        Diagnostics.shared.record("lasso.manipulate")
        editMenu.dismissMenu(); showsResizeHandles = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        manipulationChanged?(true)
    }

    private var resumeManipulation = false
    func installSelection(_ selection: UIBezierPath) {
        if resumeManipulation { showsResizeHandles = true; resumeManipulation = false }
        path = selection; completed = true; outline.path = path.cgPath
        freeResizeStale = true
        updateHandles()
        presentMenu()
    }
    private func perform(_ action: PageSelectionAction) {
        guard completed else { return }
        selected?(path.bounds.intersection(bounds), path, action)
    }
    @objc private func held(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: self)
        guard gesture.state == .began else { return }
        if completed && path.contains(point) { enterManipulation() }
        else { pasteMenuRequested?(point) }
    }
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]) -> UIMenu? {
        if let menuActions { return UIMenu(children: menuActions(path)) }
        return UIMenu(children: [
            UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.perform(.copySelection) },
            UIAction(title: "Cut", image: UIImage(systemName: "scissors")) { [weak self] _ in self?.perform(.cutSelection) },
            UIAction(title: "Duplicate", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in self?.perform(.duplicateSelection) },
            UIAction(title: "Take Screenshot", image: UIImage(systemName: "camera")) { [weak self] _ in self?.perform(.preview) }
        ])
    }
    func action(_ title: String, symbol: String, kind: PageSelectionAction, destructive: Bool = false) -> UIAction {
        UIAction(title: title, image: UIImage(systemName: symbol), attributes: destructive ? .destructive : []) { [weak self] _ in self?.perform(kind) }
    }
    private func presentMenu() {
        guard completed, !immediate, window != nil else { return }
        let point = CGPoint(x: min(max(24, path.bounds.midX), bounds.width - 24), y: max(24, path.bounds.minY - 12))
        editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
    }
    private func updateHandles() {
        if freeResizeStale, completed, showsResizeHandles { freeResizeAllowed = allowsFreeResize?(path) == true; freeResizeStale = false }
        let rect = path.bounds
        let centers = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.minY - 30), CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.midY), CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.midX, y: rect.maxY)]
        for (index, handle) in handles.enumerated() {
            handle.isHidden = !completed || immediate || !showsResizeHandles || (index >= 5 && !freeResizeAllowed)
            handle.isUserInteractionEnabled = !handle.isHidden
            handle.frame = CGRect(x: centers[index].x - 22, y: centers[index].y - 22, width: 44, height: 44)
        }
    }
    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        if completed, path.contains(point) { presentMenu(); return }
        if let selected = directSelection?(point) { installSelection(selected) }
        else { selectionDiscarded?(); clearSelection() }
    }
    @objc private func transformDragged(_ gesture: UIPanGestureRecognizer) {
        guard completed, showsResizeHandles, let handle = gesture.view, !handle.isHidden else { return }
        let point = gesture.location(in: self)
        if gesture.state == .began {
            transformOrigin = UIBezierPath(cgPath: path.cgPath); transformStart = point
            pendingScale = 1; pendingRotation = 0; editMenu.dismissMenu()
            moveBegan?(transformOrigin)
        }
        let rect = transformOrigin.bounds
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if gesture.state == .began {
            if handle.tag == 4 || gesture.modifierFlags.contains(.alternate) { transformAnchor = center }
            else {
                let anchors = [CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.minY), center, CGPoint(x: rect.maxX, y: rect.midY), CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.minY)]
                transformAnchor = anchors[handle.tag]
            }
        }
        if handle.tag == 4 {
            pendingRotation = atan2(point.y - center.y, point.x - center.x) - atan2(transformStart.y - center.y, transformStart.x - center.x)
            pendingScaleY = 1
        } else if handle.tag >= 5 {
            if handle.tag <= 6 {
                pendingScale = min(10, max(0.1, abs(point.x - transformAnchor.x) / max(1, abs(transformStart.x - transformAnchor.x))))
                pendingScaleY = gesture.modifierFlags.contains(.shift) ? pendingScale : 1
            } else {
                pendingScaleY = min(10, max(0.1, abs(point.y - transformAnchor.y) / max(1, abs(transformStart.y - transformAnchor.y))))
                pendingScale = gesture.modifierFlags.contains(.shift) ? pendingScaleY : 1
            }
        } else {
            pendingScale = min(10, max(0.1, hypot(point.x - transformAnchor.x, point.y - transformAnchor.y) / max(1, hypot(transformStart.x - transformAnchor.x, transformStart.y - transformAnchor.y))))
            pendingScaleY = pendingScale
        }
        let a = cos(pendingRotation) * pendingScale, b = sin(pendingRotation) * pendingScale
        let c = -sin(pendingRotation) * pendingScaleY, d = cos(pendingRotation) * pendingScaleY
        let anchor = transformAnchor
        path = UIBezierPath(cgPath: transformOrigin.cgPath)
        path.apply(CGAffineTransform(a: a, b: b, c: c, d: d, tx: anchor.x - a * anchor.x - c * anchor.y, ty: anchor.y - b * anchor.x - d * anchor.y))
        outline.path = path.cgPath; updateHandles()
        transformChanged?(pendingScale, pendingScaleY, pendingRotation, anchor)
        if gesture.state == .ended {
            Diagnostics.shared.record("lasso.transform", ["scale": String(format: "%.2f", pendingScale), "scaleY": String(format: "%.2f", pendingScaleY), "rotation": String(format: "%.2f", pendingRotation)])
            transformCommitted?(transformOrigin, pendingScale, pendingScaleY, pendingRotation, anchor)
            resumeManipulation = true   // stay in manipulation mode while the user keeps adjusting
            clearSelection()
        } else if gesture.state == .cancelled || gesture.state == .failed {
            moveCancelled?()
            path = transformOrigin; outline.path = path.cgPath; updateHandles()
        }
    }

    @objc private func drag(_ gesture: UIPanGestureRecognizer) {
        updateDrag(state: gesture.state, point: gesture.location(in: self), translation: gesture.translation(in: self))
    }
    func updateDrag(state: UIGestureRecognizer.State, point: CGPoint, translation: CGPoint) {
        if state == .began {
            moveCancelled?()
            editMenu.dismissMenu()
            // A pan begins only after crossing UIKit’s threshold. Hit-test the
            // contact origin: the current position may be outside a small lasso by then.
            start = CGPoint(x: point.x - translation.x, y: point.y - translation.y)
            moving = completed && path.contains(start) && moved != nil && !immediate
            if moving { originalPath = UIBezierPath(cgPath: path.cgPath); moveBegan?(originalPath) }
            else { selectionDiscarded?(); completed = false; path = UIBezierPath(); path.move(to: start) }
        }
        if moving {
            let requested = translation
            let delta = moveChanged?(requested) ?? requested
            path = UIBezierPath(cgPath: originalPath.cgPath); path.apply(CGAffineTransform(translationX: delta.x, y: delta.y))
            outline.path = path.cgPath
            updateHandles()
            if state == .ended { Diagnostics.shared.record("lasso.move", ["dx": String(Int(delta.x)), "dy": String(Int(delta.y))]); moved?(originalPath, delta); moving = false; clearSelection() }
            else if state == .cancelled || state == .failed { moveCancelled?(); path = originalPath; outline.path = path.cgPath; moving = false }
            return
        }
        guard state == .began || !path.isEmpty else { return }   // cancelled after `cancelInteraction` emptied the path
        if shape == .rectangle { path = UIBezierPath(rect: CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))) }
        else { path.addLine(to: point) }
        outline.path = path.cgPath
        if state == .ended {
            path.close()
            let rect = path.bounds.intersection(bounds)
            completed = !rect.isNull && rect.width >= 8 && rect.height >= 8
            outline.path = completed ? path.cgPath : nil
            freeResizeStale = completed
            Diagnostics.shared.record("lasso.drawn", ["completed": String(completed), "w": String(Int(path.bounds.width)), "h": String(Int(path.bounds.height))])
            updateHandles()
            if completed && immediate { perform(.preview) }
            else if completed { selectionCompleted?(path); presentMenu() }
        } else if state == .cancelled || state == .failed { completed = false; outline.path = nil }
    }
}

// Rasterize only at pickup. During dragging, UIKit translates the cached foreground.
final class SelectionDragPreview: UIView {
    let background = UIImageView()
    let foreground = UIImageView()
    let snapshot: SelectionMoveSnapshot
    let zoom: CGFloat
    private(set) var delta = CGPoint.zero
    private let guides = CAShapeLayer()
    private var guidePosition: CGPoint?
    private let offset: CGPoint
    private var stickyResize: StickyResizePreview?
    /// Called once the bitmaps are on screen: until then only the outline moves.
    var onReady: (() -> Void)?

    // `asynchronous`: rasterise off the main thread. The outline follows the finger immediately and the content
    // snaps into the preview as soon as the bitmaps are ready (they are only needed for visual feedback).
    init(frame: CGRect, page: NotePage, artwork: PageArtwork?, drawing: InkDrawing,
         snapshot: SelectionMoveSnapshot, zoom: CGFloat, offset: CGPoint, asynchronous: Bool = false) {
        self.snapshot = snapshot; self.zoom = zoom; self.offset = offset
        super.init(frame: frame)
        isUserInteractionEnabled = false; clipsToBounds = true
        background.frame = bounds; addSubview(background); addSubview(foreground)
        guides.strokeColor = UIColor.systemBlue.cgColor; guides.lineWidth = 1; guides.lineDashPattern = [4, 4]; guides.fillColor = nil; layer.addSublayer(guides)
        guard !snapshot.isEmpty else { return }
        let size = bounds.size, displayScale = traitCollection.displayScale
        let render = { Self.render(page: page, artwork: artwork, drawing: drawing, snapshot: snapshot, zoom: zoom, offset: offset, size: size, displayScale: displayScale) }
        if asynchronous {
            Task.detached(priority: .userInitiated) { [weak self] in
                let result = render()
                await MainActor.run { self?.install(result) }
            }
        } else { install(render()) }
    }
    private typealias Rendered = (background: UIImage?, backgroundFrame: CGRect, foreground: UIImage?, foregroundFrame: CGRect)
    private func install(_ rendered: Rendered?) {
        guard let rendered else { return }
        background.image = rendered.background; background.frame = rendered.backgroundFrame
        foreground.image = rendered.foreground
        // Not `frame`: the view may already carry a drag transform by the time the bitmap arrives.
        let frame = rendered.foregroundFrame
        foreground.bounds = CGRect(origin: .zero, size: frame.size); foreground.center = CGPoint(x: frame.midX, y: frame.midY)
        updateLiftShadowPath()
        onReady?(); onReady = nil
    }
    private static func padding(_ snapshot: SelectionMoveSnapshot) -> CGFloat {
        snapshot.elements.contains { $0.kind == .stickyNote && $0.stickyShadowOpacity > 0 } ? 8 : 2
    }
    private static func render(page: NotePage, artwork: PageArtwork?, drawing: InkDrawing, snapshot: SelectionMoveSnapshot,
                               zoom: CGFloat, offset: CGPoint, size: CGSize, displayScale: CGFloat) -> Rendered? {
        let end = Perf.begin("lasso.render"); defer { end() }
        let visible = CGRect(x: offset.x / zoom, y: offset.y / zoom, width: size.width / zoom, height: size.height / zoom)
            .intersection(CGRect(origin: .zero, size: snapshot.pageSize))
        guard !visible.isNull else { return nil }
        let padding = Self.padding(snapshot)
        let crop = snapshot.bounds.insetBy(dx: -padding, dy: -padding)
        // Only the area the selection leaves behind needs covering: cost follows the selection, not the screen.
        let behind = crop.intersection(visible)
        var base = page; base.elements?.removeAll { snapshot.elementIDs.contains($0.id) }
        let format = UIGraphicsImageRendererFormat(); format.scale = min(2, displayScale)
        var backgroundImage: UIImage?, backgroundFrame = CGRect.zero
        if !behind.isNull, behind.width > 0, behind.height > 0 {
            let remaining = InkDrawing(strokes: drawing.strokes.enumerated().filter {
                !snapshot.strokeIndices.contains($0.offset) && $0.element.renderBounds.intersects(behind)
            }.map(\.element)).visible(on: base)
            backgroundImage = UIGraphicsImageRenderer(size: CGSize(width: behind.width * zoom, height: behind.height * zoom), format: format).image { output in
                let context = output.cgContext
                context.scaleBy(x: zoom, y: zoom); context.translateBy(x: -behind.minX, y: -behind.minY)
                context.clip(to: behind)
                // Match the on-screen stack: paper/elements, then native translucent ink.
                PageRenderer.background(base, data: artwork?.data, resources: artwork?.resources ?? [:],
                                        context: context, pdfPage: artwork?.pdfPage, images: artwork?.images ?? [:])
                if !remaining.strokes.isEmpty { remaining.paperImage(from: behind, scale: zoom * format.scale).draw(in: behind) }
            }
            backgroundFrame = CGRect(x: behind.minX * zoom - offset.x, y: behind.minY * zoom - offset.y, width: behind.width * zoom, height: behind.height * zoom)
        }
        let scale = min(zoom * format.scale, 4096 / max(crop.width, crop.height))
        var selectedPage = page; selectedPage.elements = snapshot.elements; selectedPage.text = nil
        let ink = snapshot.ink.visible(on: selectedPage)
        let foregroundFormat = UIGraphicsImageRendererFormat(); foregroundFormat.scale = scale; foregroundFormat.opaque = false
        let foregroundImage = UIGraphicsImageRenderer(size: crop.size, format: foregroundFormat).image { output in
            output.cgContext.translateBy(x: -crop.minX, y: -crop.minY)
            PageRenderer.elements(selectedPage, resources: artwork?.resources ?? [:], context: output.cgContext,
                                  images: artwork?.images ?? [:], drewPDF: false)
            if !ink.strokes.isEmpty { ink.paperImage(from: crop, scale: scale).draw(in: crop) }
        }
        return (backgroundImage, backgroundFrame, foregroundImage, CGRect(x: crop.minX * zoom - offset.x, y: crop.minY * zoom - offset.y,
                                                         width: crop.width * zoom, height: crop.height * zoom))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func beginStickyResize(note: PageElement, page: NotePage, artwork: PageArtwork?) {
        foreground.isHidden = true
        let preview = StickyResizePreview(frame: bounds, note: note, page: page, artwork: artwork,
                                          ink: snapshot.ink, zoom: zoom, offset: offset)
        stickyResize = preview; addSubview(preview)
    }

    func resizeSticky(to size: CGSize) { stickyResize?.resize(to: size) }
    func positionSticky(at origin: CGPoint) { stickyResize?.position(at: origin) }

    private var liftScale: CGFloat = 1
    private var lastFreeDelta = CGPoint.zero
    /// Picked-up look for a dragged note: slightly larger, with a shadow, so a hold-and-drag reads as "it is moving".
    func lift() {
        liftScale = 1.04
        foreground.layer.shadowColor = UIColor.black.cgColor; foreground.layer.shadowRadius = 10
        foreground.layer.shadowOffset = CGSize(width: 0, height: 6)
        let shadow = CABasicAnimation(keyPath: "shadowOpacity"); shadow.fromValue = 0; shadow.toValue = 0.22; shadow.duration = 0.15
        foreground.layer.shadowOpacity = 0.22; foreground.layer.add(shadow, forKey: "lift")
        updateLiftShadowPath()
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.15) { self.moveFreely(by: self.lastFreeDelta) }
    }
    /// An explicit shadow shape: without it Core Animation re-derives the silhouette from the bitmap's alpha
    /// on every frame, which is what made note drags hitch on A9/A10 iPads.
    private func updateLiftShadowPath() {
        guard liftScale != 1, foreground.bounds.width > 0 else { return }
        let note = snapshot.elements.first { $0.kind == .stickyNote }
        let shape = foreground.bounds.insetBy(dx: Self.padding(snapshot) * zoom, dy: Self.padding(snapshot) * zoom)
        foreground.layer.shadowPath = UIBezierPath(roundedRect: shape, cornerRadius: CGFloat(note?.stickyRadius ?? 0) * zoom).cgPath
    }
    func moveFreely(by screenDelta: CGPoint) {
        lastFreeDelta = screenDelta
        foreground.transform = CGAffineTransform(translationX: screenDelta.x, y: screenDelta.y).scaledBy(x: liftScale, y: liftScale)
    }

    @discardableResult
    func move(by screenDelta: CGPoint) -> CGPoint {
        let requested = CGPoint(x: screenDelta.x / zoom, y: screenDelta.y / zoom)
        // Keep a captured guide until the pointer leaves a wider release band.
        let tolerance: CGFloat = guidePosition == nil ? 5 : 8
        let result = snapshot.snap(requested, tolerance: tolerance / max(0.01, zoom))
        delta = result.0; guidePosition = result.1
        let guidePath = UIBezierPath()
        if let guidePosition {
            if guidePosition.x.isFinite {
                let x = guidePosition.x * zoom - offset.x
                guidePath.move(to: CGPoint(x: x, y: 0)); guidePath.addLine(to: CGPoint(x: x, y: bounds.height))
            }
            if guidePosition.y.isFinite {
                let y = guidePosition.y * zoom - offset.y
                guidePath.move(to: CGPoint(x: 0, y: y)); guidePath.addLine(to: CGPoint(x: bounds.width, y: y))
            }
        }
        guides.path = guidePath.cgPath
        let screen = CGPoint(x: delta.x * zoom, y: delta.y * zoom)
        foreground.transform = CGAffineTransform(translationX: screen.x, y: screen.y)
        return screen
    }
}

private final class StickyResizePreview: UIView {
    private let original: PageElement
    private var note: PageElement
    private var page: NotePage
    private let artwork: PageArtwork?
    private let inkBounds: CGRect
    private let inkImage: UIImage?
    private let zoom: CGFloat
    private let offset: CGPoint

    init(frame: CGRect, note: PageElement, page: NotePage, artwork: PageArtwork?, ink: InkDrawing, zoom: CGFloat, offset: CGPoint) {
        self.original = note; self.note = note; self.page = page; self.artwork = artwork
        self.zoom = zoom; self.offset = offset
        inkBounds = ink.bounds
        if ink.strokes.isEmpty || inkBounds.isEmpty || inkBounds.isNull { inkImage = nil }
        else { inkImage = ink.paperImage(from: inkBounds, scale: min(zoom * 2, 4096 / max(inkBounds.width, inkBounds.height))) }
        super.init(frame: frame)
        isOpaque = false; isUserInteractionEnabled = false; contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func resize(to size: CGSize) { note.width = size.width; note.height = size.height; setNeedsDisplay() }
    func position(at origin: CGPoint) { note.x = origin.x; note.y = origin.y; setNeedsDisplay() }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        page.elements = page.elements?.map { $0.id == note.id ? note : $0 }
        context.translateBy(x: -offset.x, y: -offset.y); context.scaleBy(x: zoom, y: zoom)
        PageRenderer.elements(page, resources: artwork?.resources ?? [:], context: context, images: artwork?.images ?? [:], drewPDF: false)
        guard let inkImage else { return }
        context.saveGState()
        context.addPath(note.visiblePath); context.clip()
        func rotation(_ item: PageElement) -> CGAffineTransform {
            let center = CGPoint(x: item.x + item.width / 2, y: item.y + item.height / 2)
            return CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: item.rotation ?? 0).translatedBy(x: -center.x, y: -center.y)
        }
        let transform = rotation(original).inverted()
            .concatenating(CGAffineTransform(translationX: -original.x, y: -original.y))
            .concatenating(CGAffineTransform(translationX: note.x, y: note.y))
            .concatenating(rotation(note))
        context.concatenate(transform)
        inkImage.draw(in: inkBounds)
        context.restoreGState()
    }
}
