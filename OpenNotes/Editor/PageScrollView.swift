import SwiftUI
import UIKit


// The viewport keeps the existing page coordinate transform and navigation.
final class PageScrollView: UIView {
    var cloudInteractionActive: Bool {
        if editingInlineNoteID != nil || editingImages || noteMovePreview != nil || selectionPreview != nil { return true }
        guard let selectionView else { return false }
        let gestures = selectionView.activeGestures + selectionView.subviews.flatMap { $0.gestureRecognizers ?? [] }
        return gestures.contains { $0.state == .began || $0.state == .changed }
    }
    /// A drag, resize, lasso or page turn is in progress: background saving waits for it to finish.
    var isManipulating: Bool {
        if noteMovePreview != nil || selectionPreview != nil || pageTurn.committing { return true }
        let gestures = (selectionView?.activeGestures ?? []) + imageViews.flatMap { [$0] + $0.subviews }.flatMap { $0.gestureRecognizers ?? [] }
            + [pageTurn.gesture, zoomGesture, noteBodyPan]
        return gestures.contains { $0.state == .began || $0.state == .changed }
    }
    let canvas: InkCanvasView
    let paper = TiledPaperView()
    var imageViews: [ImageHandlesView] = []
    var imagePage: NotePage?
    var editingImages = false
    var imageInteractionEnabled = true { didSet { imageViews.forEach { $0.isUserInteractionEnabled = imageInteractionEnabled } } }
    var noteInteractionEnabled = true {
        didSet {
            noteViews.forEach { $0.isUserInteractionEnabled = noteInteractionEnabled }
            if !noteInteractionEnabled { selectNote(nil) }
        }
    }
    var noteBodySelectionEnabled = true {
        didSet {
            noteViews.forEach { $0.allowsBodySelection = noteBodySelectionEnabled }
            if !noteBodySelectionEnabled { selectNote(nil) }
        }
    }
    var selectedNoteID: UUID?
    var onImageEditingEnded: (() -> Void)?
    var requestedImageID: UUID?
    var stickyInsertionEnabled = false {
        didSet {
            backgroundTap.allowedTouchTypes = stickyInsertionEnabled ? [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.pencil.rawValue)] : [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        }
    }
    var onImageTap: ((CGPoint) -> Bool)?
    var onEditElement: ((PageElement) -> Void)?
    var onNoteDraft: ((PageElement) -> Void)?
    var onInsertSticky: ((CGPoint) -> Bool)?
    lazy var pageTurn = InteractivePageTurn(view: self)
    var noteViews: [StickyNoteControl] = []
    var noteMovePreview: SelectionDragPreview?
    var notesPage: NotePage?
    var noteLockedInkParents: Set<UUID> = []
    var editingInlineNoteID: UUID?
    var drawingBeforeNoteEditing = false
    var selectionView: PageSelectionView?
    var fingerScrollsSelection = false {
        didSet { selectionView?.hostGestures(on: fingerScrollsSelection ? self : nil, pencilOnly: fingerScrollsSelection) }
    }
    var selectionPreview: SelectionDragPreview?
    var selectionCommitFinished = false
    var selectionRendered = false
    var selectionCommitting = false
    var selectionPageID: UUID?
    var selectionGeneration = UUID()

    // Fingers and a resting palm must not scroll, zoom or open menus under a Pencil stroke.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if canvas.hasActivePencilStroke {
            Diagnostics.shared.record("gesture.blockedByPencil", ["gesture": String(describing: type(of: gestureRecognizer))])
            return false
        }
        if gestureRecognizer === noteBodyPan {
            let pan = noteBodyPan, now = pan.location(in: self), moved = pan.translation(in: self)
            draggedNote = note(at: CGPoint(x: now.x - moved.x, y: now.y - moved.y)).flatMap { $0.canDragBody ? $0 : nil }
            return draggedNote != nil
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
    let searchLayer = CAShapeLayer()
    var searchRects: [CGRect] = []
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if let selectionView, hit === selectionView, noteInteractionEnabled {
            for note in noteViews.reversed() where note.isUserInteractionEnabled {
                if let target = note.hitTest(convert(point, to: note), with: event) { return target }
            }
        }
        guard hit === canvas || hit?.isDescendant(of: canvas) == true else { return hit }
        let order = Dictionary(uniqueKeysWithValues: (notesPage?.elements ?? imagePage?.elements ?? []).enumerated().map { ($0.element.id, Double($0.offset)) })
        let objects: [(Double, UIView)] = noteViews.map { ($0.item.zIndex ?? order[$0.item.id] ?? 0, $0 as UIView) }
            + imageViews.map { ($0.item.zIndex ?? order[$0.item.id] ?? 0, $0 as UIView) }
        for (_, object) in objects.sorted(by: { $0.0 > $1.0 }) {
            if let image = object as? ImageHandlesView, !image.editsDirectly { continue }
            if let target = object.hitTest(convert(point, to: object), with: event) { return target }
        }
        return hit
    }
    var onPaste: ((CGPoint) -> Void)?
    var onAddSticky: ((CGPoint) -> Void)?
    /// Long press menu: only when the page is editable and fingers are not drawing.
    var longPressMenuEnabled = true
    lazy var pasteMenu = UIEditMenuInteraction(delegate: self)
    var onWindowReady: (() -> Void)?
    override func didMoveToWindow() { super.didMoveToWindow(); onWindowReady?() }
    @objc func windowBecameKey(_ notification: Notification) {
        if let ready = notification.object as? UIWindow, ready === window { onWindowReady?() }
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    var onNavigate: ((Int) async -> Bool)?
    var verticalPaging = false
    let fitGesture = UITapGestureRecognizer()
    let backgroundTap = UITapGestureRecognizer()
    let pasteHold = UILongPressGestureRecognizer()
    var fingerDrawing = false {
        didSet {
            guard oldValue != fingerDrawing else { return }
            fitGesture.numberOfTouchesRequired = fingerDrawing ? 2 : 1
            pageTurn.gesture.minimumNumberOfTouches = fingerDrawing ? 2 : 1
            pageTurn.gesture.maximumNumberOfTouches = fingerDrawing ? 2 : 1
        }
    }
    var positionKey: String?
    var savedPosition: [Double]?
    var pageSize = CGSize.zero
    var needsFit = true
    var initialZoom: CGFloat?
    var viewportSize = CGSize.zero
    var layingOut = false
    let zoomGesture = UIPinchGestureRecognizer()
    lazy var noteNavigationPan = StickyNavigationPan(target: self, action: #selector(panOverNote(_:)))
    /// One-finger drag of the selected note's body; open note bodies do not capture touches themselves.
    let noteBodyPan = StickyDragPan()
    weak var draggedNote: StickyNoteControl?
    var noteNavigationTranslation = CGPoint.zero
    var noteNavigationEnabled: (canvas: Bool, pageTurn: Bool)?
    var pinchOrigin: (zoom: CGFloat, scale: CGFloat, point: CGPoint)?

    init(canvas: InkCanvasView) {
        self.canvas = canvas
        super.init(frame: .zero)
        NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey(_:)), name: UIWindow.didBecomeKeyNotification, object: nil)
        backgroundColor = .secondarySystemBackground
        clipsToBounds = true
        paper.backgroundColor = .white
        paper.isUserInteractionEnabled = false
        addSubview(paper)
        canvas.overrideUserInterfaceStyle = .light
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = true

        canvas.minimumZoomScale = 0.1
        canvas.maximumZoomScale = 4
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.pinchGestureRecognizer?.isEnabled = false
        zoomGesture.addTarget(self, action: #selector(pinchChanged(_:)))
        zoomGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        zoomGesture.delegate = self; addGestureRecognizer(zoomGesture)
        noteNavigationPan.delegate = self
        noteNavigationPan.trackingChanged = { [weak self] tracking in
            guard let self else { return }
            if tracking {
                self.noteNavigationEnabled = (self.canvas.panGestureRecognizer.isEnabled, self.pageTurn.gesture.isEnabled)
                self.canvas.panGestureRecognizer.isEnabled = false
                self.pageTurn.gesture.isEnabled = false
                self.noteNavigationTranslation = .zero
            } else if let enabled = self.noteNavigationEnabled {
                self.canvas.panGestureRecognizer.isEnabled = enabled.canvas
                self.pageTurn.gesture.isEnabled = enabled.pageTurn
                self.noteNavigationEnabled = nil
            }
        }
        noteNavigationPan.additionalTouch = { [weak self] in
            guard let self, let note = self.noteNavigationPan.note else { return }
            let gestures = (note.gestureRecognizers ?? []) + note.subviews.flatMap { $0.gestureRecognizers ?? [] }
            for gesture in gestures where gesture is UIPanGestureRecognizer || gesture is UILongPressGestureRecognizer {
                gesture.isEnabled = false; gesture.isEnabled = true
            }
            self.clearNoteMovePreview()
            self.alignBackground()
        }
        addGestureRecognizer(noteNavigationPan)
        canvas.accessibilityLabel = "Handwriting page"
        canvas.accessibilityIdentifier = "editor.canvas"
        addSubview(canvas)
        backgroundTap.addTarget(self, action: #selector(tappedBackground(_:)))
        backgroundTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        backgroundTap.cancelsTouchesInView = false; backgroundTap.delegate = self
        addGestureRecognizer(backgroundTap)
        fitGesture.addTarget(self, action: #selector(doubleTap(_:)))
        fitGesture.numberOfTapsRequired = 2
        fitGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        fitGesture.delegate = self; addGestureRecognizer(fitGesture)
        pasteHold.addTarget(self, action: #selector(showPasteMenu(_:)))
        pasteHold.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pasteHold.delegate = self
        canvas.addGestureRecognizer(pasteHold); addInteraction(pasteMenu)
        canvas.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Fit width") { [weak self] _ in self?.fitAxis(horizontal: true); return true },
            UIAccessibilityCustomAction(name: "Fit height") { [weak self] _ in self?.fitAxis(horizontal: false); return true },
            UIAccessibilityCustomAction(name: "Paste at page center") { [weak self] _ in
            guard let self else { return false }
            self.onPaste?(CGPoint(x: self.pageSize.width / 2, y: self.pageSize.height / 2)); return true
        }]
        _ = pageTurn
        canvas.panGestureRecognizer.require(toFail: pageTurn.gesture)
        noteBodyPan.addTarget(self, action: #selector(dragNoteBody(_:)))
        noteBodyPan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        noteBodyPan.maximumNumberOfTouches = 1
        noteBodyPan.delegate = self; addGestureRecognizer(noteBodyPan)
        // Decided at the pan threshold, so scrolling waits on nothing when the touch is not on a selected note.
        canvas.panGestureRecognizer.require(toFail: noteBodyPan)
        pageTurn.gesture.require(toFail: noteBodyPan)
        searchLayer.fillColor = UIColor.systemYellow.withAlphaComponent(0.35).cgColor
        searchLayer.strokeColor = UIColor.systemOrange.cgColor
        layer.addSublayer(searchLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, pageSize.width > 0, pageSize.height > 0 else { return }
        if viewportSize != .zero && viewportSize != bounds.size { pinchOrigin = nil; pageTurn.clear() }
        let oldCenter = CGPoint(x: (canvas.contentOffset.x + canvas.bounds.width / 2) / canvas.zoomScale, y: (canvas.contentOffset.y + canvas.bounds.height / 2) / canvas.zoomScale)
        let oldZoom = canvas.zoomScale
        let wasAtFit = abs(oldZoom - canvas.minimumZoomScale) < 0.02
        let firstFit = needsFit
        layingOut = true
        if canvas.frame != bounds { canvas.frame = bounds }
        if needsFit || viewportSize != bounds.size {
            Diagnostics.shared.record("viewport.layout", ["width": String(Double(bounds.width)), "height": String(Double(bounds.height)), "zoom": String(Double(oldZoom)), "fitted": String(wasAtFit), "first": String(firstFit)])
            needsFit = false
            viewportSize = bounds.size
            canvas.minimumZoomScale = 0.1
            canvas.setZoomScale(1, animated: false)
            canvas.setPageSize(pageSize)
            canvas.contentSize = pageSize
            let fit = max(0.1, min(4, (bounds.width - 32) / pageSize.width, (bounds.height - 32) / pageSize.height))
            canvas.minimumZoomScale = fit
            let restored = firstFit ? Self.restoredZoom(savedPosition, fit: fit) : (wasAtFit ? fit : oldZoom)
            canvas.setZoomScale(max(fit, min(4, initialZoom ?? restored ?? fit)), animated: false)
            canvas.layoutIfNeeded()
            layingOut = false
            alignBackground()
            if firstFit, let savedPosition {
                canvas.contentOffset = CGPoint(x: savedPosition[1] * canvas.zoomScale - bounds.width / 2, y: savedPosition[2] * canvas.zoomScale - bounds.height / 2)
            } else if !firstFit && !wasAtFit {
                canvas.contentOffset = CGPoint(x: oldCenter.x * canvas.zoomScale - bounds.width / 2, y: oldCenter.y * canvas.zoomScale - bounds.height / 2)
            } else { canvas.contentOffset = CGPoint(x: -canvas.contentInset.left, y: -canvas.contentInset.top) }
            canvas.contentOffset = boundedOffset(canvas.contentOffset)
        }
        layingOut = false
        alignBackground()
    }
    var lastAlignedZoom: CGFloat = 0
}

extension PageScrollView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === fitGesture {
            var target = touch.view
            while let view = target, view !== self {
                if view is StickyNoteControl { return false }
                target = view.superview
            }
        }
        guard gestureRecognizer === backgroundTap else { return true }
        let onCanvas = touch.view === canvas || touch.view?.isDescendant(of: canvas) == true
        guard selectionView == nil || stickyInsertionEnabled || (fingerScrollsSelection && (onCanvas || touch.view === selectionView)) else { return false }
        var target = touch.view
        while let view = target, view !== self {
            if view is ImageHandlesView || view is StickyNoteControl { return false }
            target = view.superview
        }
        return true
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
}
