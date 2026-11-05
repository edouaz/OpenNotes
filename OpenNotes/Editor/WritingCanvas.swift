import SwiftUI
import UIKit

struct WritingCanvas: UIViewRepresentable {
    @ObservedObject var session: EditorSession
    var finger: Bool
    var reading: Bool
    var zoomWindow = false
    var verticalPaging = false
    var editingImages = false
    var imageToSelect: UUID?
    var pageDirection = 1
    var previousPreview: UIImage?
    var nextPreview: UIImage?
    var hasPrevious = false
    var hasNext = false
    var selectionMode = false
    var immediateSelection = false
    var selectedRect: ((CGRect, UIBezierPath, PageSelectionAction) -> Void)?
    var pasted: (() -> Void)?
    var editNote: ((PageElement) -> Void)?
    var editImage: ((UUID) -> Void)?
    var imageEditingEnded: (() -> Void)?
    var selectionMoved: ((UIBezierPath, CGPoint) async -> Bool)?
    var prepare: ((Int) -> Void)?
    var addPage: ((Int) async -> Bool)?
    var navigate: ((Int) async -> Bool)?
    func makeCoordinator() -> Coordinator { Coordinator(session: session, zoomWindow: zoomWindow) }
    func makeUIView(context: Context) -> PageScrollView {
        let view = PageScrollView(canvas: context.coordinator.activeCanvas)
        context.coordinator.container = view
        session.registerCanvas(view.canvas)
        view.canvas.delegate = context.coordinator
        view.canvas.inkDelegate = context.coordinator
        view.onWindowReady = { [weak coordinator = context.coordinator] in
            coordinator?.updateInteraction()
        }
        view.onNavigate = navigate
        return view
    }
    func updateUIView(_ view: PageScrollView, context: Context) {
        guard let page = session.page else { return }
        if !selectionMode && session.selectedTool != .lasso {
            view.configureSelection(false, session: session, immediate: false, selected: nil)
        }
        let canvas = view.canvas
        canvas.occludingNotes = page.elements ?? []
        canvas.lockedParentIDs = Set((page.elements ?? []).filter { $0.isLocked == true }.map(\.id))
        let hiddenParents = page.collapsedContentParents
        // Skip the per-stroke scan (and layer sweep) in the common case of no collapsed notes.
        let hiddenIDs = hiddenParents.isEmpty ? [] : Set(session.drawing.strokes.filter { $0.parentID.map { hiddenParents.contains($0) } == true }.map(\.id))
        if canvas.hiddenStrokeIDs != hiddenIDs { canvas.hiddenStrokeIDs = hiddenIDs }
        if view.pageSize != PageRenderer.size(page) { view.savePosition(); view.pageSize = PageRenderer.size(page); view.needsFit = true; view.setNeedsLayout() }
        context.coordinator.reading = reading
        context.coordinator.updateInteraction()
        view.onNavigate = navigate
        view.pageTurn.previous = previousPreview; view.pageTurn.next = nextPreview
        view.pageTurn.canPrevious = hasPrevious; view.pageTurn.canNext = hasNext
        view.pageTurn.addPage = addPage
        view.pageTurn.prepare = prepare
        if reading { view.finishNoteEditing() }
        let inlineEditing = view.editingInlineNoteID != nil
        let insertingSticky = session.stickyInsertionColor != nil && !reading
        view.stickyInsertionEnabled = insertingSticky
        view.fingerScrollsSelection = !finger
        let selecting = !inlineEditing && !insertingSticky && (selectionMode || (!reading && !editingImages && session.selectedTool == .lasso))
        // Page turning is a finger gesture; the lasso is Pencil-driven (or finger-driven only in finger mode, handled below).
        view.pageTurn.disabled = editingImages || session.busy
        view.onImageEditingEnded = imageEditingEnded
        canvas.panGestureRecognizer.minimumNumberOfTouches = reading || !finger ? 1 : 2
        canvas.settings = session.toolSettings
        canvas.selectedTool = session.selectedTool
        canvas.onCommit = { [weak coordinator = context.coordinator] drawing, name in
            guard let coordinator, coordinator.pageID == coordinator.session.page?.id else { return }
            coordinator.session.replaceDrawing(drawing, actionName: name)
            if coordinator.zoomWindow { coordinator.activeCanvas.drawing = drawing }
        }
        canvas.onEraserEnded = { [weak session] in session?.finishErasing() }
        canvas.onStrokeBegan = { [weak coordinator = context.coordinator] in coordinator?.circle = nil }
        canvas.onEstimatedStrokeUpdate = { [weak session] drawing in
            guard let session else { return }
            session.canvas.drawing = drawing
            session.changed(drawing)
        }
        canvas.onCompletedStroke = { [weak coordinator = context.coordinator] stroke in
            coordinator?.completed(stroke)
        }
        canvas.canCircleLongPress = { [weak coordinator = context.coordinator] point in coordinator?.canSelectCircle(at: point) == true }
        canvas.onCircleLongPress = { [weak coordinator = context.coordinator] point in
            guard let coordinator, coordinator.canSelectCircle(at: point), let circle = coordinator.circle else { return false }
            coordinator.circle = nil
            coordinator.session.replaceDrawing(InkDrawing(strokes: coordinator.session.drawing.strokes.filter { $0.id != circle.id }), actionName: "Circle to lasso")
            coordinator.session.selectedTool = .lasso
            coordinator.container?.configureSelection(true, session: coordinator.session, immediate: false,
                shape: coordinator.session.toolSettings.lassoShape, moved: selectionMoved, selected: selectedRect)
            coordinator.container?.installCircleSelection(circle.contour)
            return true
        }
        view.configureSelection(selecting, session: session, immediate: immediateSelection, shape: session.toolSettings.lassoShape, moved: selectionMoved, selected: selectedRect)
        view.onPaste = { point in
            let pageID = session.page?.id
            let existing = Set((session.page?.elements ?? []).filter { $0.kind == .image }.map(\.id))
            Task {
                await session.paste(at: point)
                pasted?()
                if session.page?.id == pageID, let added = session.page?.elements?.last(where: { $0.kind == .image && !existing.contains($0.id) }) {
                    editImage?(added.id)
                }
            }
        }
        view.verticalPaging = verticalPaging
        view.fingerDrawing = finger
        canvas.tool = session.tool
        canvas.isRulerActive = session.toolSettings.rulerEnabled == true && !reading && !editingImages && !selecting
        canvas.drawingPolicy = finger ? .anyInput : .pencilOnly
        let drawingEnabled = !reading && !editingImages && !selecting && !insertingSticky && !inlineEditing
        if !drawingEnabled { canvas.cancelActiveStroke() }
        canvas.drawingGestureRecognizer.isEnabled = drawingEnabled
        if finger && !reading { view.pageTurn.disabled = true }
        if context.coordinator.pageID != page.id {
            canvas.cancelActiveStroke()
            context.coordinator.circle = nil
            context.coordinator.loading = true
            view.pageSize = PageRenderer.size(page)
            if zoomWindow || session.canvasPageID != page.id {
                canvas.drawing = session.drawing
                canvas.undoManager?.removeAllActions()
                context.coordinator.updateUndoAvailability()
                if !zoomWindow { session.canvasPageID = page.id }
            }
            context.coordinator.pageID = page.id
            view.initialZoom = zoomWindow ? 2 : nil
            view.restorePosition(page.id, noteID: session.noteID)
            view.needsFit = true
            view.setNeedsLayout()
            context.coordinator.loading = false
        }
        var paperPage = page
        // Static objects share the export renderer; interaction overlays do not repaint them.
        if editingImages { paperPage.elements?.removeAll { $0.kind == .image } }
        view.configureNotes(page, edit: reading ? nil : editNote, session: session) { [weak view] item, id in
            let preview = view?.noteMovePreview
            Task {
                let saved = await session.apply(.init(pageID: page.id, kind: item == nil ? .removeElement : .upsertElement, element: item, elementID: id))
                if saved { view?.selectNote(item.flatMap { $0.collapsed != true && $0.isLocked != true ? $0.id : nil }) }
                if saved, item == nil {
                    view?.showUndoToast("Sticky note deleted") { session.canvas.undoManager?.undo(); session.refreshUndoAvailability() }
                }
                if !saved, let current = session.page { view?.restoreNotes(from: current) }
                if view?.noteMovePreview === preview { view?.clearNoteMovePreview() }
            }
        }
        view.onEditElement = editNote
        view.onNoteDraft = { [weak session] note in session?.stageStickyEdit(note) }
        view.onDirectSelection = { [weak view, weak session] point in
            guard let view, let session, !session.isReadOnly, !reading, !finger, !editingImages, session.stickyInsertionColor == nil, let page = session.page else { return false }
            let logical = CGPoint(x: (point.x + canvas.contentOffset.x) / canvas.zoomScale, y: (point.y + canvas.contentOffset.y) / canvas.zoomScale)
            let hit = UIBezierPath(ovalIn: CGRect(x: logical.x - 4 / canvas.zoomScale, y: logical.y - 4 / canvas.zoomScale, width: 8 / canvas.zoomScale, height: 8 / canvas.zoomScale))
            let snapshot = SelectionMoveSnapshot(page: page, drawing: canvas.drawing, path: hit, settings: session.toolSettings)
            guard !snapshot.isEmpty else { return false }
            let noteIDs = Set((page.elements ?? []).filter { $0.kind == .stickyNote }.map(\.id))
            if snapshot.elements.contains(where: { $0.kind == .stickyNote }) || snapshot.ink.strokes.contains(where: { $0.parentID.map { noteIDs.contains($0) } == true }) { return false }
            if snapshot.ink.strokes.isEmpty, snapshot.elements.count == 1, let item = snapshot.elements.first, item.kind == .image, let editImage {
                editImage(item.id)
                return true
            }
            session.selectedTool = .lasso
            view.configureSelection(true, session: session, immediate: false, shape: session.toolSettings.lassoShape, moved: selectionMoved, selected: selectedRect)
            let selection = UIBezierPath(rect: snapshot.bounds)
            selection.apply(CGAffineTransform(a: canvas.zoomScale, b: 0, c: 0, d: canvas.zoomScale, tx: -canvas.contentOffset.x, ty: -canvas.contentOffset.y))
            view.installDirectSelection(selection)
            return true
        }
        view.longPressMenuEnabled = !reading && !session.isReadOnly && !finger && !editingImages && !inlineEditing
        view.onAddSticky = { [weak session, weak view] point in
            guard let session, !session.isReadOnly else { return }
            let pageID = session.page?.id
            let existing = Set((session.page?.elements ?? []).map(\.id))
            Task {
                guard await session.insertSticky(at: point, color: session.stickyInsertionColor ?? session.toolSettings.stickyColorHex ?? "#FFE66D"),
                      session.page?.id == pageID,
                      let added = session.page?.elements?.last(where: { $0.kind == .stickyNote && !existing.contains($0.id) }) else { return }
                view?.selectNote(added.id)
            }
        }
        view.onInsertSticky = { [weak session, weak view] point in
            guard let session, session.stickyInsertionColor != nil, !session.isReadOnly else { return false }
            let pageID = session.page?.id
            let existing = Set((session.page?.elements ?? []).map(\.id))
            Task {
                guard await session.insertSticky(at: point), session.page?.id == pageID,
                      let added = session.page?.elements?.last(where: { $0.kind == .stickyNote && !existing.contains($0.id) }) else { return }
                view?.selectNote(added.id)
            }
            return true
        }
        view.noteBodySelectionEnabled = !finger
        view.noteInteractionEnabled = !reading && !session.isReadOnly && !selectionMode && !insertingSticky
        view.imageInteractionEnabled = !reading && !insertingSticky
        view.showSearchHighlights(session.searchHighlights)
        view.configurePaper(page: paperPage, artwork: session.artwork)
        view.configureImages(page, images: session.artwork?.images ?? [:], pencil: editingImages, beginEditing: editImage) { item, id in
            Task { await session.apply(.init(pageID: page.id, kind: item == nil ? .removeElement : .upsertElement, element: item, elementID: id)) }
        }
        view.selectRequestedImage(editingImages ? imageToSelect : nil)
        // Native ink and previews share one renderer throughout the gesture.
        view.updateAccessibilityElements()
        view.layoutIfNeeded()
        view.pageTurn.pageInstalled(page.id)
    }
    static func dismantleUIView(_ view: PageScrollView, coordinator: Coordinator) {
        view.onWindowReady = nil
        view.canvas.cancelActiveStroke()
        view.canvas.onCommit = nil; view.canvas.onCompletedStroke = nil
        view.canvas.onEraserEnded = nil
        view.canvas.onStrokeBegan = nil; view.canvas.onEstimatedStrokeUpdate = nil
        view.canvas.canCircleLongPress = nil; view.canvas.onCircleLongPress = nil
        coordinator.container = nil
        view.pageTurn.detach()
        view.detachInteractions()
        view.savePosition()
        if view.canvas.delegate === coordinator { view.canvas.delegate = nil; view.canvas.inkDelegate = nil }
    }

    final class Coordinator: NSObject, InkCanvasViewDelegate {
        let session: EditorSession
        let zoomWindow: Bool
        let zoomCanvas = InkCanvasView()
        weak var container: PageScrollView?
        var activeCanvas: InkCanvasView { zoomWindow ? zoomCanvas : session.canvas }
        var pageID: UUID?
        var loading = false
        var reading = false
        var circle: (id: UUID, contour: [CGPoint], expires: TimeInterval)?
        init(session: EditorSession, zoomWindow: Bool) {
            self.session = session; self.zoomWindow = zoomWindow
            super.init()
            for name in [Notification.Name.NSUndoManagerDidCloseUndoGroup, Notification.Name.NSUndoManagerDidUndoChange, Notification.Name.NSUndoManagerDidRedoChange] {
                NotificationCenter.default.addObserver(self, selector: #selector(undoHistoryChanged), name: name, object: session.canvas.undoManager)
            }
        }
        deinit { NotificationCenter.default.removeObserver(self) }
        @objc private func undoHistoryChanged() { updateUndoAvailability() }
        func updateInteraction() {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.container != nil else { return }
                if !self.reading && self.container?.editingInlineNoteID == nil && self.activeCanvas.window?.isKeyWindow == true { self.activeCanvas.becomeFirstResponder() }
                self.session.refreshUndoAvailability()
            }
        }
        func updateUndoAvailability() {
            DispatchQueue.main.async { [weak session] in session?.refreshUndoAvailability() }
        }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { activeCanvas.inkContentView }
        func scrollViewDidScroll(_ scrollView: UIScrollView) { container?.alignBackground() }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { container?.alignBackground() }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { container?.savePosition() }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { container?.savePosition() } }
        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) { container?.alignBackground(); container?.savePosition() }
        func canvasViewDrawingDidChange(_ canvas: InkCanvasView) {}
        func canvasViewDidBeginUsingTool(_ canvas: InkCanvasView) {}
        func canvasViewDidEndUsingTool(_ canvas: InkCanvasView) { updateUndoAvailability() }
        func canvasViewDidFinishRendering(_ canvas: InkCanvasView) { container?.selectionDidRender() }
        func completed(_ stroke: InkStroke) -> InkDrawing? {
            let previous = session.drawing
            circle = nil
            guard stroke.ink.inkType != .marker, stroke.ink.inkType != .pencil else { return nil }
            let raw = stroke.rawSamples.map { $0.location.applying(stroke.transform) }
            if InkGestureRecognition.isScribble(raw, over: previous) {
                let erased = EraserEditing.erase(previous, along: raw, width: max(12, (stroke.style?.width ?? 3) * 3), mode: .pixel)
                if EraserEditing.changed(erased, previous) { return erased }
            }
            if InkGestureRecognition.circle(raw) != nil {
                circle = (stroke.id, raw, ProcessInfo.processInfo.systemUptime + 4)
            }
            return nil
        }
        func canSelectCircle(at point: CGPoint) -> Bool {
            guard [.pen, .fountainPen].contains(session.selectedTool),
                  let circle, circle.expires > ProcessInfo.processInfo.systemUptime,
                  pageID == session.page?.id, session.drawing.strokes.contains(where: { $0.id == circle.id }) else { return false }
            return InkGestureRecognition.isOnContour(point, contour: circle.contour, tolerance: 12 / max(0.1, activeCanvas.zoomScale))
        }
    }
}

// The viewport keeps the existing page coordinate transform and navigation.
final class PageScrollView: UIView {
    var cloudInteractionActive: Bool {
        if editingInlineNoteID != nil || editingImages || noteMovePreview != nil || selectionPreview != nil { return true }
        guard let selectionView else { return false }
        let gestures = selectionView.activeGestures + selectionView.subviews.flatMap { $0.gestureRecognizers ?? [] }
        return gestures.contains { $0.state == .began || $0.state == .changed }
    }
    let canvas: InkCanvasView
    let paper = TiledPaperView()
    private var imageViews: [ImageHandlesView] = []
    private var imagePage: NotePage?
    private var editingImages = false
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
    private(set) var selectedNoteID: UUID?
    func selectNote(_ id: UUID?) {
        selectedNoteID = id
        for note in noteViews { note.setObjectSelected(note.item.id == id) }
    }
    var onImageEditingEnded: (() -> Void)?
    private var requestedImageID: UUID?
    private func selectImage(_ id: UUID?) { imageViews.forEach { $0.showsHandles = $0.item.id == id } }
    func selectRequestedImage(_ id: UUID?) {
        guard requestedImageID != id else { return }
        requestedImageID = id
        if let id { selectImage(id) }
    }
    func deselectImages() { selectImage(nil); onImageEditingEnded?() }
    var stickyInsertionEnabled = false {
        didSet {
            backgroundTap.allowedTouchTypes = stickyInsertionEnabled ? [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.pencil.rawValue)] : [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        }
    }
    var onDirectSelection: ((CGPoint) -> Bool)?
    var onEditElement: ((PageElement) -> Void)?
    var onNoteDraft: ((PageElement) -> Void)?
    var onInsertSticky: ((CGPoint) -> Bool)?
    @objc private func tappedBackground(_ tap: UITapGestureRecognizer) {
        let point = tap.location(in: self)
        let logical = CGPoint(x: (point.x + canvas.contentOffset.x) / canvas.zoomScale, y: (point.y + canvas.contentOffset.y) / canvas.zoomScale)
        selectNote(nil)
        if onInsertSticky?(logical) == true { return }
        if onDirectSelection?(point) == true { return }
        deselectImages()
    }
    func configureImages(_ page: NotePage?, images: [String: UIImage], pencil: Bool, beginEditing: ((UUID) -> Void)? = nil, changed: @escaping (PageElement?, UUID) -> Void) {
        let entering = pencil && !editingImages
        let leaving = !pencil && editingImages
        editingImages = pencil
        imageViews.forEach { $0.editableWithPencil = pencil; $0.editsDirectly = pencil; $0.preview.isHidden = !pencil }
        let sameImages = imagePage?.id == page?.id && imagePage.map(PageRenderer.size) == page.map(PageRenderer.size) &&
            imagePage?.elements?.filter { $0.kind == .image } == page?.elements?.filter { $0.kind == .image } &&
            imagePage?.collapsedContentParents == page?.collapsedContentParents
        let assetsChanged = imageViews.contains { view in view.item.resource.flatMap { images[$0] } !== view.preview.image }
        if sameImages && !assetsChanged {
            if entering { selectImage(imageViews.last?.item.id) }
            if leaving { selectImage(nil) }
            return
        }
        let previousIDs = Set(imageViews.map { $0.item.id })
        let selected = imagePage?.id == page?.id ? imageViews.first(where: { $0.showsHandles })?.item.id : nil
        imagePage = page
        imageViews.forEach { $0.removeFromSuperview() }; imageViews.removeAll()
        let hiddenParents = page?.collapsedContentParents ?? []
        for item in page?.elements ?? [] where item.kind == .image && item.parentID.map({ !hiddenParents.contains($0) }) != false {
            let view = ImageHandlesView(item: item, image: item.resource.flatMap { images[$0] })
            view.editsDirectly = pencil; view.preview.isHidden = !pencil
            view.pageSize = pageSize; view.editableWithPencil = pencil; view.showsHandles = !leaving && selected == item.id
            view.changed = { changed($0, item.id) }
            view.selected = { [weak self] in
                guard let self else { return }
                if self.editingImages { self.selectImage(item.id) }
                else { beginEditing?(item.id) }
            }
            imageViews.append(view); insertSubview(view, belowSubview: canvas)
        }
        if pencil, let added = imageViews.last(where: { !previousIDs.contains($0.item.id) }) { selectImage(added.item.id) }
        else if entering { selectImage(imageViews.last?.item.id) }
        alignBackground()
    }
    lazy var pageTurn = InteractivePageTurn(view: self)
    private var noteViews: [StickyNoteControl] = []
    func updateAccessibilityElements() {
        // Transparent canvas overlays must not hide the document's editing controls from VoiceOver.
        accessibilityElements = [canvas] + (selectionView.map { [$0 as UIView] } ?? []) + noteViews + imageViews
    }
    private(set) var noteMovePreview: SelectionDragPreview?
    func clearNoteMovePreview() { noteMovePreview?.removeFromSuperview(); noteMovePreview = nil }
    private var notesPage: NotePage?
    private var noteLockedInkParents: Set<UUID> = []
    private(set) var editingInlineNoteID: UUID?
    private var drawingBeforeNoteEditing = false
    private var selectionView: PageSelectionView?
    var fingerScrollsSelection = false {
        didSet { selectionView?.hostGestures(on: fingerScrollsSelection ? self : nil, pencilOnly: fingerScrollsSelection) }
    }
    private(set) var selectionPreview: SelectionDragPreview?
    private var selectionCommitFinished = false
    private var selectionRendered = false
    private var selectionCommitting = false
    private var selectionPageID: UUID?
    private var selectionGeneration = UUID()

    func clearSelectionPreview() {
        selectionGeneration = UUID()
        selectionPreview?.removeFromSuperview(); selectionPreview = nil
        selectionCommitFinished = false; selectionRendered = false; selectionCommitting = false
        selectionView?.isUserInteractionEnabled = true
    }
    func selectionDidRender() {
        guard selectionCommitting else { return }
        selectionRendered = true
        if selectionCommitFinished {
            let generation = selectionGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.selectionGeneration == generation, self.selectionCommitFinished else { return }
                self.clearSelectionPreview()
            }
        }
    }

    private let searchLayer = CAShapeLayer()
    private var searchRects: [CGRect] = []
    func showSearchHighlights(_ rects: [CGRect]) { guard searchRects != rects else { return }; searchRects = rects; alignBackground() }
    func configureSelection(_ enabled: Bool, session: EditorSession? = nil, immediate: Bool, shape: EditorToolSettings.LassoShape = .freeform, moved: ((UIBezierPath, CGPoint) async -> Bool)? = nil, selected: ((CGRect, UIBezierPath, PageSelectionAction) -> Void)?) {
        pasteHold.isEnabled = !enabled
        if !enabled || selectionPageID != session?.page?.id {
            clearSelectionPreview(); selectionView?.clearSelection()
        }
        selectionPageID = session?.page?.id
        if !enabled { selectionView?.detachGestures(); selectionView?.removeFromSuperview(); selectionView = nil; return }
        if selectionView == nil { let overlay = PageSelectionView(); selectionView = overlay; addSubview(overlay) }
        selectionView?.hostGestures(on: fingerScrollsSelection ? self : nil, pencilOnly: fingerScrollsSelection)
        selectionView?.frame = bounds
        selectionView?.immediate = immediate
        selectionView?.shape = shape
        selectionView?.directSelection = { [weak self, weak session] point in
            guard let self, let session, let page = session.page, !session.isReadOnly else { return nil }
            let logical = CGPoint(x: (point.x + self.canvas.contentOffset.x) / self.canvas.zoomScale, y: (point.y + self.canvas.contentOffset.y) / self.canvas.zoomScale)
            let hit = UIBezierPath(ovalIn: CGRect(x: logical.x - 4 / self.canvas.zoomScale, y: logical.y - 4 / self.canvas.zoomScale, width: 8 / self.canvas.zoomScale, height: 8 / self.canvas.zoomScale))
            let snapshot = SelectionMoveSnapshot(page: page, drawing: self.canvas.drawing, path: hit, settings: session.toolSettings)
            guard !snapshot.isEmpty else { return nil }
            let noteIDs = Set((page.elements ?? []).filter { $0.kind == .stickyNote }.map(\.id))
            if snapshot.elements.contains(where: { $0.kind == .stickyNote }) || snapshot.ink.strokes.contains(where: { $0.parentID.map { noteIDs.contains($0) } == true }) { return nil }
            session.selectedTool = .lasso
            let selected = UIBezierPath(rect: snapshot.bounds)
            selected.apply(CGAffineTransform(a: self.canvas.zoomScale, b: 0, c: 0, d: self.canvas.zoomScale, tx: -self.canvas.contentOffset.x, ty: -self.canvas.contentOffset.y))
            return selected
        }
        selectionView?.transformCommitted = { [weak self, weak session] path, scale, scaleY, rotation, anchor in
            guard let self, let session else { return }
            let logical = self.logicalPath(path)
            guard let overlay = self.selectionView else { return }
            let tool = session.selectedTool, generation = self.selectionGeneration
            self.selectionCommitting = true; self.selectionRendered = false
            overlay.isUserInteractionEnabled = false
            let pageAnchor = CGPoint(x: (anchor.x + self.canvas.contentOffset.x) / self.canvas.zoomScale, y: (anchor.y + self.canvas.contentOffset.y) / self.canvas.zoomScale)
            Task { @MainActor [weak self] in
                let success = await session.affineSelection(inside: logical, scale: scale, rotation: rotation, scaleY: scaleY, anchor: pageAnchor, durable: false)
                guard let self, self.selectionView === overlay, session.selectedTool == tool, self.selectionGeneration == generation else { return }
                self.selectionCommitFinished = true
                if !success { self.clearSelectionPreview() }
                else if self.selectionRendered { self.selectionDidRender() }
                if success {
                    let a = cos(rotation) * scale, b = sin(rotation) * scale
                    let c = -sin(rotation) * scaleY, d = cos(rotation) * scaleY
                    let transformed = UIBezierPath(cgPath: path.cgPath)
                    transformed.apply(CGAffineTransform(a: a, b: b, c: c, d: d, tx: anchor.x - a * anchor.x - c * anchor.y, ty: anchor.y - b * anchor.x - d * anchor.y))
                    self.selectionView?.installSelection(transformed)
                }
            }
        }
        selectionView?.transformChanged = { [weak self] scale, scaleY, rotation, anchor in
            guard let foreground = self?.selectionPreview?.foreground else { return }
            let center = foreground.center
            let a = cos(rotation) * scale, b = sin(rotation) * scale
            let c = -sin(rotation) * scaleY, d = cos(rotation) * scaleY
            let transformed = center.applying(CGAffineTransform(a: a, b: b, c: c, d: d, tx: anchor.x - a * anchor.x - c * anchor.y, ty: anchor.y - b * anchor.x - d * anchor.y))
            foreground.transform = CGAffineTransform(a: a, b: b, c: c, d: d, tx: transformed.x - center.x, ty: transformed.y - center.y)
        }
        selectionView?.allowsFreeResize = { [weak self, weak session] path in
            guard let self, let session, let page = session.page else { return false }
            let snapshot = SelectionMoveSnapshot(page: page, drawing: self.canvas.drawing, path: self.logicalPath(path), settings: session.toolSettings)
            guard !snapshot.containsLockedObjects, snapshot.ink.strokes.isEmpty, snapshot.elements.count == 1, let item = snapshot.elements.first else { return false }
            return (item.kind == .stickyNote || item.kind == .text) && abs(item.rotation ?? 0) < 0.001
        }
        selectionView?.menuActions = { [weak self, weak session] path in
            guard let self, let session, let page = session.page, let overlay = self.selectionView else { return [] }
            let snapshot = SelectionMoveSnapshot(page: page, drawing: self.canvas.drawing, path: self.logicalPath(path), settings: session.toolSettings)
            var actions: [UIMenuElement] = [
                overlay.action("Take Screenshot", symbol: "camera", kind: .preview),
                overlay.action("Quick Screenshot & Copy", symbol: "doc.on.clipboard", kind: .copyPhoto)
            ]
            guard !snapshot.isEmpty else { return actions }
            actions.insert(overlay.action("Copy", symbol: "doc.on.doc", kind: .copySelection), at: 0)
            let locked = snapshot.containsLockedObjects
            if !session.isReadOnly && !locked {
                actions.append(UIAction(title: "Resize & Rotate", image: UIImage(systemName: "arrow.up.left.and.arrow.down.right")) { [weak overlay] _ in
                    overlay?.enterManipulation()
                })
                actions.insert(contentsOf: [overlay.action("Cut", symbol: "scissors", kind: .cutSelection), overlay.action("Duplicate", symbol: "plus.square.on.square", kind: .duplicateSelection)], at: 1)
                actions.append(overlay.action("Delete", symbol: "trash", kind: .deleteContent, destructive: true))
                if !snapshot.ink.strokes.isEmpty || snapshot.elements.contains(where: { $0.kind != .image }) {
                    actions.append(overlay.action("Use Current Ink Color", symbol: "paintpalette", kind: .recolorSelection))
                }
                if !snapshot.elements.isEmpty && snapshot.ink.strokes.isEmpty {
                    actions.append(overlay.action("Bring to Front", symbol: "square.3.layers.3d.top.filled", kind: .bringFront))
                    actions.append(overlay.action("Send to Back", symbol: "square.3.layers.3d.bottom.filled", kind: .sendBack))
                }
            }
            if !session.isReadOnly {
                if !locked, snapshot.elements.count == 1, let item = snapshot.elements.first, item.kind == .stickyNote || item.kind == .text {
                    actions.append(overlay.action("Edit Text", symbol: "text.cursor", kind: .editText))
                    actions.append(overlay.action("Format Text…", symbol: "textformat", kind: .formatText))
                }
                actions.append(overlay.action(locked ? "Unlock" : "Lock", symbol: locked ? "lock.open" : "lock", kind: .lockSelection))
                if !locked, snapshot.elements.contains(where: { $0.kind == .stickyNote }) {
                    actions.append(overlay.action("Collapse / Expand", symbol: "rectangle.compress.vertical", kind: .collapseSelection))
                }
            }
            return actions
        }
        selectionView?.moveBegan = { [weak self, weak session] path in
            guard let self, let session, let page = session.page else { return }
            self.clearSelectionPreview()
            let snapshot = SelectionMoveSnapshot(page: page, drawing: self.canvas.drawing,
                                                 path: self.logicalPath(path), settings: session.toolSettings)
            guard !snapshot.isEmpty, !snapshot.containsLockedObjects, self.canvas.zoomScale > 0 else { return }
            let preview = SelectionDragPreview(frame: self.bounds, page: page, artwork: session.artwork,
                                               drawing: self.canvas.drawing, snapshot: snapshot,
                                               zoom: self.canvas.zoomScale, offset: self.canvas.contentOffset, asynchronous: true)
            self.selectionPreview = preview
            if let overlay = self.selectionView { self.insertSubview(preview, belowSubview: overlay) }
        }
        selectionView?.moveChanged = { [weak self] delta in self?.selectionPreview?.move(by: delta) ?? .zero }
        selectionView?.moveCancelled = { [weak self] in self?.clearSelectionPreview() }
        selectionView?.moved = moved.map { moved in
            { [weak self, weak session] path, delta in
                guard let self, let session else { return }
                let pagePath = self.logicalPath(path)
                let logicalDelta = CGPoint(x: delta.x / self.canvas.zoomScale, y: delta.y / self.canvas.zoomScale)
                guard let overlay = self.selectionView else { return }
                let tool = session.selectedTool, generation = self.selectionGeneration
                let preview = self.selectionPreview
                self.selectionCommitting = true; self.selectionRendered = false
                self.selectionView?.isUserInteractionEnabled = false
                Task { @MainActor [weak self] in
                    let success = await moved(pagePath, logicalDelta)
                    guard let self, self.selectionView === overlay, session.selectedTool == tool, self.selectionGeneration == generation, self.selectionPreview === preview else { return }
                    self.selectionCommitFinished = true
                    if !success || logicalDelta == .zero || preview?.snapshot.ink.strokes.isEmpty != false {
                        self.clearSelectionPreview()
                    } else if self.selectionRendered { self.selectionDidRender() }
                    if success {
                        let transformed = UIBezierPath(cgPath: path.cgPath)
                        transformed.apply(CGAffineTransform(translationX: delta.x, y: delta.y))
                        self.selectionView?.installSelection(transformed)
                    }
                }
            }
        }
        selectionView?.pasteMenuRequested = { [weak self] point in
            self?.pasteMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
        }
        selectionView?.pasteRequested = { [weak self] point in self?.requestPaste(at: point) }
        selectionView?.selected = { [weak self, weak session] rect, path, action in
            guard let self else { return }
            let logical = CGRect(x: (rect.minX + self.canvas.contentOffset.x) / self.canvas.zoomScale,
                                 y: (rect.minY + self.canvas.contentOffset.y) / self.canvas.zoomScale,
                                 width: rect.width / self.canvas.zoomScale, height: rect.height / self.canvas.zoomScale)
                .intersection(CGRect(origin: .zero, size: self.pageSize))
            if !logical.isNull {
                let pagePath = self.logicalPath(path)
                switch action {
                case .copySelection, .cutSelection, .duplicateSelection, .lockSelection, .collapseSelection, .bringFront, .sendBack, .recolorSelection:
                    guard let session else { return }
                    Task { await session.selectionAction(action, path: pagePath) }
                    if action != .copySelection { self.selectionView?.clearSelection() }
                case .editText:
                    guard let session, let page = session.page else { return }
                    let snapshot = SelectionMoveSnapshot(page: page, drawing: self.canvas.drawing, path: pagePath, settings: session.toolSettings)
                    if let item = snapshot.elements.first, item.isLocked != true {
                        if item.kind == .stickyNote, let note = self.noteViews.first(where: { $0.item.id == item.id }) {
                            self.clearSelectionPreview(); self.selectionView?.clearSelection()
                            self.selectionView?.detachGestures(); self.selectionView?.removeFromSuperview(); self.selectionView = nil
                            self.pasteHold.isEnabled = true
                            self.noteInteractionEnabled = true
                            self.canvas.drawingGestureRecognizer.isEnabled = false
                            note.beginInlineEditing()
                        } else { self.onEditElement?(item) }
                    }
                case .formatText:
                    guard let session, let page = session.page else { return }
                    let snapshot = SelectionMoveSnapshot(page: page, drawing: self.canvas.drawing, path: pagePath, settings: session.toolSettings)
                    if let item = snapshot.elements.first, item.isLocked != true { self.onEditElement?(item) }
                case .preview, .copyPhoto:
                    // The page screenshot is rectangular even for a freehand lasso.
                    selected?(logical, UIBezierPath(rect: logical), action)
                default: selected?(logical, pagePath, action)
                }
            }
        }
        if let selectionView { bringSubviewToFront(selectionView) }
    }
    func installDirectSelection(_ selection: UIBezierPath) { selectionView?.installSelection(selection) }
    func installCircleSelection(_ contour: [CGPoint]) {
        guard let first = contour.first else { return }
        let path = UIBezierPath(); path.move(to: first)
        for point in contour.dropFirst() { path.addLine(to: point) }
        path.close()
        path.apply(CGAffineTransform(a: canvas.zoomScale, b: 0, c: 0, d: canvas.zoomScale, tx: -canvas.contentOffset.x, ty: -canvas.contentOffset.y))
        selectionView?.installSelection(path)
    }
    private func logicalPath(_ path: UIBezierPath) -> UIBezierPath {
        let result = UIBezierPath(cgPath: path.cgPath), zoom = canvas.zoomScale
        result.apply(CGAffineTransform(a: 1 / zoom, b: 0, c: 0, d: 1 / zoom, tx: canvas.contentOffset.x / zoom, ty: canvas.contentOffset.y / zoom))
        return result
    }
    func finishNoteEditing() {
        for note in noteViews where note.isEditingInline { note.endInlineEditing() }
        editingInlineNoteID = nil
    }
    func configurePaper(page: NotePage, artwork: PageArtwork?) {
        var rendered = page
        if let id = editingInlineNoteID, let index = rendered.elements?.firstIndex(where: { $0.id == id }) {
            rendered.elements?[index].text = ""
            rendered.elements?[index].richTextRTF = nil
        }
        if editingImages { rendered.elements?.removeAll { $0.kind == .image } }
        paper.configure(page: rendered, artwork: artwork)
    }
    func restoreNotes(from page: NotePage) {
        for note in noteViews {
            if let current = page.elements?.first(where: { $0.id == note.item.id }) {
                note.item = current
                note.setObjectSelected(false)
                note.setObjectSelected(current.id == selectedNoteID)
            }
        }
        clearNoteMovePreview()
        alignBackground()
    }
    func configureNotes(_ page: NotePage, edit: ((PageElement) -> Void)?, session: EditorSession? = nil, changed: @escaping (PageElement?, UUID) -> Void) {
        if notesPage?.id == page.id, let editing = noteViews.first(where: { $0.isEditingInline }),
           let latest = page.elements?.first(where: { $0.id == editing.item.id }), latest.isLocked != true, latest.collapsed != true {
            editing.item = latest
            return
        }
        let lockedInkParents = Set(session?.drawing.strokes.compactMap { $0.isLocked == true ? $0.parentID : nil } ?? [])
        guard notesPage?.id != page.id || notesPage.map(PageRenderer.size) != PageRenderer.size(page) ||
                notesPage?.elements != page.elements || noteLockedInkParents != lockedInkParents else { return }
        noteLockedInkParents = lockedInkParents
        if notesPage?.id != page.id { clearNoteMovePreview(); selectedNoteID = nil }
        if notesPage?.id == page.id {
            let previousIDs = Set((notesPage?.elements ?? []).map(\.id))
            if let added = page.elements?.last(where: { $0.kind == .stickyNote && !previousIDs.contains($0.id) && $0.isLocked != true && $0.collapsed != true }) { selectedNoteID = added.id }
        }
        let selection = selectedNoteID
        if !((page.elements ?? []).contains { $0.id == selection && $0.isLocked != true && $0.collapsed != true }) { selectedNoteID = nil }
        notesPage = page
        noteViews.forEach { $0.removeFromSuperview() }; noteViews = []
        let hiddenParents = page.collapsedContentParents
        for item in page.elements ?? [] where item.kind == .stickyNote && item.parentID.map({ !hiddenParents.contains($0) }) != false {
            let control = StickyNoteControl(item: item)
            control.selectsBeforeEditing = false
            control.allowsBodySelection = noteBodySelectionEnabled
            control.isUserInteractionEnabled = noteInteractionEnabled
            control.setObjectSelected(item.id == selectedNoteID)
            control.selectionChanged = { [weak self] selected in
                guard selected else { return }
                self?.selectNote(item.id)
                self?.deselectImages()
            }
            control.contextualAction = { [weak session] action in
                Task { await session?.stickyAction(action, id: item.id) }
            }
            control.draftChanged = { [weak self] note in self?.onNoteDraft?(note) }
            control.inlineEditingChanged = { [weak self, weak session] editing in
                guard let self else { return }
                self.editingInlineNoteID = editing ? item.id : nil
                if editing {
                    self.drawingBeforeNoteEditing = self.canvas.drawingGestureRecognizer.isEnabled
                    self.canvas.cancelActiveStroke(); self.canvas.drawingGestureRecognizer.isEnabled = false
                } else { self.canvas.drawingGestureRecognizer.isEnabled = self.drawingBeforeNoteEditing }
                if let current = session?.pageIncludingDrafts ?? self.notesPage {
                    self.configurePaper(page: current, artwork: session?.artwork)
                }
                self.onWindowReady?()
            }
            var ownedIDs: Set<UUID> = [item.id]
            var count = 0
            while count != ownedIDs.count {
                count = ownedIDs.count
                for child in page.elements ?? [] where child.parentID.map({ ownedIDs.contains($0) }) == true { ownedIDs.insert(child.id) }
            }
            let owned = (page.elements ?? []).filter { ownedIDs.contains($0.id) }
            control.movementBounds = owned.reduce(CGRect.null) { $0.union(CGRect(x: $1.x, y: $1.y, width: $1.width, height: $1.height)) }
            control.canManipulate = !owned.contains { $0.isLocked == true } && lockedInkParents.isDisjoint(with: ownedIDs)
            control.pageSize = pageSize; control.changed = { changed($0, item.id) }
            control.movePreviewBegan = { [weak self, weak session, weak control] in
                guard let self, let session, let control, let current = session.page else { return }
                self.clearNoteMovePreview()
                var isolated = current
                let elements = current.elements ?? []
                var ids: Set<UUID> = [item.id]
                var previousCount = 0
                while ids.count != previousCount {
                    previousCount = ids.count
                    for element in elements where element.parentID.map({ ids.contains($0) }) == true { ids.insert(element.id) }
                }
                isolated.elements = elements.filter { ids.contains($0.id) }
                var settings = session.toolSettings
                settings.includeHandwriting = false; settings.includeStickyNotes = true
                let snapshot = SelectionMoveSnapshot(page: isolated, drawing: self.canvas.drawing, path: UIBezierPath(rect: item.visibleBounds), settings: settings)
                guard snapshot.elementIDs.contains(item.id), !snapshot.containsLockedObjects else { return }
                let preview = SelectionDragPreview(frame: self.bounds, page: current, artwork: session.artwork,
                                                   drawing: self.canvas.drawing, snapshot: snapshot,
                                                   zoom: self.canvas.zoomScale, offset: self.canvas.contentOffset)
                self.noteMovePreview = preview; self.addSubview(preview); self.bringSubviewToFront(control)
            }
            control.movePreviewChanged = { [weak self] delta in
                guard let self else { return }
                let zoom = self.canvas.zoomScale
                let x = min(max(0, item.x + delta.x / zoom), max(0, self.pageSize.width - item.width))
                let y = min(max(0, item.y + delta.y / zoom), max(0, self.pageSize.height - item.height))
                self.noteMovePreview?.moveFreely(by: CGPoint(x: (x - item.x) * zoom, y: (y - item.y) * zoom))
            }
            control.movePreviewCancelled = { [weak self] in self?.clearNoteMovePreview() }
            control.resizePreviewBegan = { [weak self, weak session, weak control] in
                guard let self, let session, let control, let current = session.page else { return }
                control.movePreviewBegan?()
                guard let preview = self.noteMovePreview else { return }
                var selected = current
                selected.elements = preview.snapshot.elements; selected.text = nil
                preview.beginStickyResize(note: item, page: selected, artwork: session.artwork)
            }
            control.resizePreviewChanged = { [weak self] size in self?.noteMovePreview?.resizeSticky(to: size) }
            control.resizePreviewPositionChanged = { [weak self] origin in self?.noteMovePreview?.positionSticky(at: origin) }
            control.resizePreviewCancelled = { [weak self] in self?.clearNoteMovePreview() }
            control.edit = { [weak self, weak control] in
                guard let self, let control else { return }
                if self.onDirectSelection?(control.center) != true { edit?(item) }
            }
            noteViews.append(control); insertSubview(control, belowSubview: canvas)
        }
        alignBackground()
    }
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
    @objc private func windowBecameKey(_ notification: Notification) {
        if let ready = notification.object as? UIWindow, ready === window { onWindowReady?() }
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    var onNavigate: ((Int) async -> Bool)?
    var verticalPaging = false
    private let fitGesture = UITapGestureRecognizer()
    private let backgroundTap = UITapGestureRecognizer()
    private let pasteHold = UILongPressGestureRecognizer()
    func detachInteractions() {
        pinchOrigin = nil
        selectionView?.detachGestures()
        noteNavigationPan.reset()
        removeGestureRecognizer(noteNavigationPan)
        for gesture in [fitGesture, pasteHold] { gesture.view?.removeGestureRecognizer(gesture) }
        zoomGesture.removeTarget(self, action: #selector(pinchChanged(_:)))
        removeGestureRecognizer(zoomGesture)
        if canvas.superview === self { canvas.pinchGestureRecognizer?.isEnabled = true }
        clearSelectionPreview()
    }
    var fingerDrawing = false {
        didSet {
            guard oldValue != fingerDrawing else { return }
            fitGesture.numberOfTouchesRequired = fingerDrawing ? 2 : 1
            pageTurn.gesture.minimumNumberOfTouches = fingerDrawing ? 2 : 1
            pageTurn.gesture.maximumNumberOfTouches = fingerDrawing ? 2 : 1
        }
    }
    private var positionKey: String?
    private var savedPosition: [Double]?
    static func restoredZoom(_ saved: [Double]?, fit: CGFloat) -> CGFloat? {
        guard let saved, (3...4).contains(saved.count), saved.allSatisfy(\.isFinite), saved[0] > 0 else { return nil }
        return saved.count == 4 && abs(saved[0] - saved[3]) < 0.02 ? fit : CGFloat(saved[0])
    }
    func restorePosition(_ id: UUID, noteID: UUID) {
        pinchOrigin = nil
        savePosition()
        positionKey = "viewport-\(noteID)-\(id)"
        let saved = UserDefaults.standard.array(forKey: positionKey!) as? [Double]
        savedPosition = Self.restoredZoom(saved, fit: canvas.minimumZoomScale) == nil ? nil : saved
    }
    func savePosition() {
        Diagnostics.shared.record("viewport.settled", ["zoom": String(format: "%.2f", canvas.zoomScale), "x": String(Int(canvas.contentOffset.x)), "y": String(Int(canvas.contentOffset.y))])
        guard let positionKey, !needsFit, canvas.zoomScale > 0 else { return }
        UserDefaults.standard.set([Double(canvas.zoomScale), Double((canvas.contentOffset.x + bounds.width / 2) / canvas.zoomScale), Double((canvas.contentOffset.y + bounds.height / 2) / canvas.zoomScale), Double(canvas.minimumZoomScale)], forKey: positionKey)
    }
    @objc private func doubleTap(_ gesture: UITapGestureRecognizer) {
        toggleFit(at: gesture.location(in: self))
    }
    var widthFitZoom: CGFloat {
        min(canvas.maximumZoomScale, max(canvas.minimumZoomScale, (bounds.width - 32) / pageSize.width))
    }
    var heightFitZoom: CGFloat {
        min(canvas.maximumZoomScale, max(canvas.minimumZoomScale, (bounds.height - 32) / pageSize.height))
    }
    func toggleFit(at point: CGPoint) {
        let atWidth = abs(canvas.zoomScale - widthFitZoom) <= max(0.002, widthFitZoom * 0.015)
        fitAxis(horizontal: !atWidth, at: point)
    }
    func fitAxis(horizontal: Bool, at point: CGPoint? = nil) {
        guard pageSize.width > 0, pageSize.height > 0 else { return }
        pinchOrigin = nil
        let anchor = point ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let logical = CGPoint(x: (anchor.x + canvas.contentOffset.x) / canvas.zoomScale,
                              y: (anchor.y + canvas.contentOffset.y) / canvas.zoomScale)
        let zoom = horizontal ? widthFitZoom : heightFitZoom
        let update = {
            self.canvas.setZoomScale(zoom, animated: false)
            self.alignBackground()
            self.canvas.contentOffset = self.boundedOffset(CGPoint(
                x: horizontal ? -self.canvas.contentInset.left : logical.x * zoom - anchor.x,
                y: horizontal ? logical.y * zoom - anchor.y : -self.canvas.contentInset.top))
        }
        if UIAccessibility.isReduceMotionEnabled { update() }
        else { UIView.animate(withDuration: 0.22, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut], animations: update) }
        savePosition()
    }
    @objc func fitPage() {
        let fit = max(0.1, min(4, (bounds.width - 32) / pageSize.width, (bounds.height - 32) / pageSize.height))
        let update = {
            self.canvas.setZoomScale(fit, animated: false)
            self.alignBackground()
            self.canvas.contentOffset = CGPoint(x: -self.canvas.contentInset.left, y: -self.canvas.contentInset.top)
        }
        if UIAccessibility.isReduceMotionEnabled { update() }
        else { UIView.animate(withDuration: 0.2, animations: update) }
        savePosition()
    }
    var pageSize = CGSize.zero
    var needsFit = true
    var initialZoom: CGFloat?
    private var viewportSize = CGSize.zero
    private var layingOut = false
    let zoomGesture = UIPinchGestureRecognizer()
    private lazy var noteNavigationPan = StickyNavigationPan(target: self, action: #selector(panOverNote(_:)))
    private var noteNavigationTranslation = CGPoint.zero
    private var noteNavigationEnabled: (canvas: Bool, pageTurn: Bool)?
    @objc private func panOverNote(_ pan: UIPanGestureRecognizer) {
        let translation = pan.translation(in: self)
        defer { noteNavigationTranslation = translation }
        if pan.state == .began { noteNavigationTranslation = .zero }
        if (pan.state == .began || pan.state == .changed) && !isPinching {
            canvas.contentOffset = boundedOffset(CGPoint(
                x: canvas.contentOffset.x - (translation.x - noteNavigationTranslation.x),
                y: canvas.contentOffset.y - (translation.y - noteNavigationTranslation.y)))
            alignBackground()
        }
        if pan.state == .ended || pan.state == .cancelled { savePosition() }
    }
    var isPinching: Bool { zoomGesture.state == .began || zoomGesture.state == .changed }
    private var pinchOrigin: (zoom: CGFloat, scale: CGFloat, point: CGPoint)?

    @objc private func pinchChanged(_ pinch: UIPinchGestureRecognizer) {
        // The parent receives touches over images too; the native canvas owns ink rendering.
        let location = pinch.location(in: self)
        if pinch.state == .began {
            Diagnostics.shared.record("zoom.begin", ["scale": String(Double(canvas.zoomScale))])
            pinchOrigin = (canvas.zoomScale, pinch.scale, CGPoint(
                x: (canvas.contentOffset.x + location.x) / canvas.zoomScale,
                y: (canvas.contentOffset.y + location.y) / canvas.zoomScale))
        } else if pinch.state == .changed, let origin = pinchOrigin {
            let zoom = max(canvas.minimumZoomScale, min(canvas.maximumZoomScale, origin.zoom * pinch.scale / origin.scale))
            canvas.setZoomScale(zoom, animated: false)
            alignBackground()
            canvas.contentOffset = boundedOffset(CGPoint(x: origin.point.x * zoom - location.x, y: origin.point.y * zoom - location.y))
        } else if pinch.state == .ended || pinch.state == .cancelled || pinch.state == .failed {
            Diagnostics.shared.record("zoom.end", ["scale": String(Double(canvas.zoomScale))])
            pinchOrigin = nil; alignBackground(); savePosition()
        }
    }

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
    func boundedOffset(_ proposed: CGPoint) -> CGPoint {
        let minimum = CGPoint(x: -canvas.contentInset.left, y: -canvas.contentInset.top)
        return CGPoint(
            x: min(max(minimum.x, proposed.x), max(minimum.x, pageSize.width * canvas.zoomScale - bounds.width + canvas.contentInset.right)),
            y: min(max(minimum.y, proposed.y), max(minimum.y, pageSize.height * canvas.zoomScale - bounds.height + canvas.contentInset.bottom)))
    }
    private var lastAlignedZoom: CGFloat = 0
    /// Runs on every scroll frame: only offset-dependent work (positions) is unconditional;
    /// size, font and the accessibility value are redone only when the zoom changes.
    func alignBackground() {
        guard !layingOut, pageSize.width > 0 else { return }
        let zoom = canvas.zoomScale, offset = canvas.contentOffset
        let zoomChanged = zoom != lastAlignedZoom
        lastAlignedZoom = zoom
        if zoomChanged { canvas.accessibilityValue = "Zoom \(Int((zoom / max(0.01, canvas.minimumZoomScale) * 100).rounded())) %" }
        let size = CGSize(width: pageSize.width * zoom, height: pageSize.height * zoom)
        let horizontal = max(0, (bounds.width - size.width) / 2)
        let vertical = max(0, (bounds.height - size.height) / 2)
        let inset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        if canvas.contentInset != inset { canvas.contentInset = inset }
        // Keep tile coordinates stable throughout a pinch; only the transform changes.
        paper.bounds = CGRect(origin: .zero, size: pageSize)
        paper.transform = CGAffineTransform(scaleX: zoom, y: zoom)
        paper.center = CGPoint(x: -offset.x + size.width / 2, y: -offset.y + size.height / 2)
        if !searchRects.isEmpty || searchLayer.path != nil {
            let path = UIBezierPath()
            for rect in searchRects {
                path.append(UIBezierPath(rect: CGRect(x: rect.minX * zoom - offset.x, y: rect.minY * zoom - offset.y, width: rect.width * zoom, height: rect.height * zoom)))
            }
            searchLayer.path = searchRects.isEmpty ? nil : path.cgPath
        }
        for note in noteViews {
            if noteMovePreview != nil && note.item.id == selectedNoteID { continue }
            note.zoom = zoom
            let width = note.item.collapsed == true ? 44 : note.item.width
            let height = note.item.collapsed == true ? 44 : note.item.height
            let target = CGSize(width: max(44, width * zoom), height: max(44, height * zoom))
            if zoomChanged || note.bounds.size != target {
                note.transform = .identity
                note.bounds = CGRect(origin: .zero, size: target)
                note.titleLabel?.font = .systemFont(ofSize: max(12, 16 * zoom))
                note.setNeedsLayout()
            }
            note.center = CGPoint(x: (note.item.x + width / 2) * zoom - offset.x, y: (note.item.y + height / 2) * zoom - offset.y)
            note.transform = CGAffineTransform(rotationAngle: note.item.rotation ?? 0)
        }
        selectionView?.frame = bounds
        selectionView?.follow(zoom: zoom, offset: offset)
        if let selectionView { bringSubviewToFront(selectionView) }
        for view in imageViews {
            view.zoom = zoom
            let target = CGSize(width: view.item.width * zoom, height: view.item.height * zoom)
            if zoomChanged || view.bounds.size != target {
                view.transform = .identity
                view.bounds = CGRect(origin: .zero, size: target)
                view.setNeedsLayout()
            }
            view.center = CGPoint(x: (view.item.x + view.item.width / 2) * zoom - offset.x, y: (view.item.y + view.item.height / 2) * zoom - offset.y)
            view.transform = CGAffineTransform(rotationAngle: view.item.rotation ?? 0)
        }
    }
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
