import SwiftUI
import UIKit

// Sticky notes, inline editing and image handles.
extension PageScrollView {
    func selectNote(_ id: UUID?) {
        selectedNoteID = id
        for note in noteViews { note.setObjectSelected(note.item.id == id) }
    }
    /// Topmost open note whose body contains `point` (in this view), using the document's stacking order.
    func note(at point: CGPoint) -> StickyNoteControl? {
        guard noteInteractionEnabled else { return nil }
        let order = Dictionary(uniqueKeysWithValues: (notesPage?.elements ?? []).enumerated().map { ($0.element.id, Double($0.offset)) })
        return noteViews.filter(\.isUserInteractionEnabled)
            .sorted { ($0.item.zIndex ?? order[$0.item.id] ?? 0) > ($1.item.zIndex ?? order[$1.item.id] ?? 0) }
            .first { $0.bodyContains(convert(point, to: $0)) }
    }
    @objc func dragNoteBody(_ pan: UIPanGestureRecognizer) {
        draggedNote?.drag(pan)
        if pan.state == .ended || pan.state == .cancelled || pan.state == .failed { draggedNote = nil }
    }
    func selectImage(_ id: UUID?) { imageViews.forEach { $0.showsHandles = $0.item.id == id } }
    func selectRequestedImage(_ id: UUID?) {
        guard requestedImageID != id else { return }
        requestedImageID = id
        if let id { selectImage(id) }
    }
    func deselectImages() { selectImage(nil); onImageEditingEnded?() }
    @objc func tappedBackground(_ tap: UITapGestureRecognizer) {
        let point = tap.location(in: self)
        let logical = CGPoint(x: (point.x + canvas.contentOffset.x) / canvas.zoomScale, y: (point.y + canvas.contentOffset.y) / canvas.zoomScale)
        if noteBodySelectionEnabled, let note = note(at: point) {
            Diagnostics.shared.record("tap.note", ["selected": String(note.isObjectSelected)])
            note.tapBodyFromPage(); return
        }
        selectNote(nil)
        if onInsertSticky?(logical) == true { Diagnostics.shared.record("tap.background", ["result": "stickyInserted"]); return }
        if onImageTap?(point) == true { Diagnostics.shared.record("tap.background", ["result": "imageOpened"]); return }
        Diagnostics.shared.record("tap.background", ["result": "none", "tool": String(describing: type(of: canvas.tool))])
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
        // Edited images keep their view: recreating every view on each move or resize made them flash and drop a quick second grab.
        var reusable = Dictionary(imageViews.map { ($0.item.id, $0) }, uniquingKeysWith: { first, _ in first })
        imageViews.removeAll()
        let hiddenParents = page?.collapsedContentParents ?? []
        for item in page?.elements ?? [] where item.kind == .image && item.parentID.map({ !hiddenParents.contains($0) }) != false {
            let image = item.resource.flatMap { images[$0] }
            let view: ImageHandlesView
            if let existing = reusable.removeValue(forKey: item.id), existing.preview.image === image {
                view = existing; view.item = item
            } else { view = ImageHandlesView(item: item, image: image) }
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
        reusable.values.forEach { $0.removeFromSuperview() }
        if pencil, let added = imageViews.last(where: { !previousIDs.contains($0.item.id) }) { selectImage(added.item.id) }
        else if entering { selectImage(imageViews.last?.item.id) }
        alignBackground()
    }
    func updateAccessibilityElements() {
        // Transparent canvas overlays must not hide the document's editing controls from VoiceOver.
        accessibilityElements = [canvas] + (selectionView.map { [$0 as UIView] } ?? []) + noteViews + imageViews
    }
    func clearNoteMovePreview() {
        if noteMovePreview != nil { FrameMonitor.shared.end() }
        noteMovePreview?.removeFromSuperview(); noteMovePreview = nil
    }
    func finishNoteEditing() {
        for note in noteViews where note.isEditingInline { note.endInlineEditing() }
        editingInlineNoteID = nil
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
                let end = Perf.begin("sticky.pickup"); defer { end() }
                let started = CACurrentMediaTime()
                defer { Diagnostics.shared.record("sticky.pickup", ["mainThreadMs": elapsedMilliseconds(since: started), "pageStrokes": String(self.canvas.drawing.strokes.count)]) }
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
                if !control.isResizing { preview.lift() }
                FrameMonitor.shared.begin("sticky.drag")
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
            control.edit = { edit?(item) }
            noteViews.append(control); insertSubview(control, belowSubview: canvas)
        }
        alignBackground()
    }
}
