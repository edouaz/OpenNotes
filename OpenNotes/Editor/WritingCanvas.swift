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
        let end = Perf.begin("canvas.update"); defer { end() }
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
        view.pageTurn.disabled = editingImages || session.busy || !AppPreferences.swipePaging
        view.fitGesture.isEnabled = AppPreferences.doubleTapFit
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
            let started = CACurrentMediaTime()
            Task {
                let saved = await session.apply(.init(pageID: page.id, kind: item == nil ? .removeElement : .upsertElement, element: item, elementID: id), durable: false)
                Diagnostics.shared.record("sticky.commit", ["ms": elapsedMilliseconds(since: started), "saved": String(saved), "kind": item == nil ? "delete" : "update"])
                if saved { view?.selectNote(item.flatMap { $0.collapsed != true && $0.isLocked != true ? $0.id : nil }) }
                if saved, item == nil {
                    view?.showUndoToast("Sticky note deleted") { session.canvas.undoManager?.undo(); session.refreshUndoAvailability() }
                }
                if !saved, let current = session.page { view?.restoreNotes(from: current) }
                // The lifted preview covers the note until the paper has redrawn it at its new place.
                if saved { view?.paper.whenDrawn { if view?.noteMovePreview === preview { view?.clearNoteMovePreview() } } }
                else if view?.noteMovePreview === preview { view?.clearNoteMovePreview() }
            }
        }
        view.onEditElement = editNote
        view.onNoteDraft = { [weak session] note in session?.stageStickyEdit(note) }
        // A finger tap never selects ink or changes the tool; it only opens a tapped image for placement.
        view.onImageTap = { [weak session] point in
            guard let session, let editImage, !session.isReadOnly, !reading, !finger, !editingImages, session.stickyInsertionColor == nil,
                  let page = session.page, page.elements?.contains(where: { $0.kind == .image }) == true else { return false }
            let logical = CGPoint(x: (point.x + canvas.contentOffset.x) / canvas.zoomScale, y: (point.y + canvas.contentOffset.y) / canvas.zoomScale)
            let hit = UIBezierPath(ovalIn: CGRect(x: logical.x - 4 / canvas.zoomScale, y: logical.y - 4 / canvas.zoomScale, width: 8 / canvas.zoomScale, height: 8 / canvas.zoomScale))
            let snapshot = SelectionMoveSnapshot(page: page, drawing: canvas.drawing, path: hit, settings: session.toolSettings)
            guard snapshot.ink.strokes.isEmpty, snapshot.elements.count == 1, let item = snapshot.elements.first, item.kind == .image else { return false }
            editImage(item.id)
            return true
        }
        view.longPressMenuEnabled = !reading && !session.isReadOnly && !finger && !editingImages && !inlineEditing
        // Disabled rather than ignored: a recognized hold would cancel the finger stroke under it.
        view.pasteHold.isEnabled = view.longPressMenuEnabled && !selecting
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
            let started = CACurrentMediaTime()
            Task {
                let saved = await session.apply(.init(pageID: page.id, kind: item == nil ? .removeElement : .upsertElement, element: item, elementID: id), durable: false)
                Diagnostics.shared.record("image.commit", ["ms": elapsedMilliseconds(since: started), "saved": String(saved), "kind": item == nil ? "delete" : "update"])
            }
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
            for name in [Notification.Name.NSUndoManagerDidUndoChange, Notification.Name.NSUndoManagerDidRedoChange] {
                NotificationCenter.default.addObserver(self, selector: #selector(contentRestored), name: name, object: session.canvas.undoManager)
            }
        }
        deinit { NotificationCenter.default.removeObserver(self) }
        @objc private func undoHistoryChanged() { updateUndoAvailability() }
        // ponytail: drops the selection; follow the restored objects once selections are stored by ID.
        @objc private func contentRestored() {
            Diagnostics.shared.record("selection.cancelledByUndo", ["hadSelection": String(container?.selectionView?.selectionBounds.isEmpty == false)])
            container?.cancelSelection()
        }
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
            if AppPreferences.scratchOutErase, InkGestureRecognition.isScribble(raw, over: previous) {
                // Scratch-out removes every stroke the scribble crosses, whole, instead of rubbing out pixels.
                let erased = EraserEditing.erase(previous, along: raw, width: max(6, (stroke.style?.width ?? 3) * 1.5), mode: .stroke)
                if EraserEditing.changed(erased, previous) {
                    Diagnostics.shared.record("scribble.erase", ["removed": String(previous.strokes.count - erased.strokes.count)])
                    return erased
                }
            }
            if AppPreferences.circleToSelect, InkGestureRecognition.circle(raw) != nil {
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
