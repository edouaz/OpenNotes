import SwiftUI
import UIKit

// Lasso / circle selection session, preview and commit.
extension PageScrollView {

    func clearSelectionPreview() {
        selectionGeneration = UUID()
        selectionPreview?.removeFromSuperview(); selectionPreview = nil
        selectionCommitFinished = false; selectionRendered = false; selectionCommitting = false
        selectionView?.isUserInteractionEnabled = true
    }
    func cancelSelection() { clearSelectionPreview(); selectionView?.selectionDiscarded?(); selectionView?.cancelInteraction() }
    func selectionDidRender() {
        guard selectionCommitting else { return }
        selectionRendered = true
        if selectionCommitFinished {
            let generation = selectionGeneration
            // Moved objects drawn by the paper (notes, images, text) are kept on the preview until their tiles are redrawn.
            paper.whenDrawn { [weak self] in
                guard let self, self.selectionGeneration == generation, self.selectionCommitFinished else { return }
                self.clearSelectionPreview()
            }
        }
    }
    func configureSelection(_ enabled: Bool, session: EditorSession? = nil, immediate: Bool, shape: EditorToolSettings.LassoShape = .freeform, moved: ((UIBezierPath, CGPoint) async -> Bool)? = nil, selected: ((CGRect, UIBezierPath, PageSelectionAction) -> Void)?) {
        pasteHold.isEnabled = !enabled
        if !enabled || selectionPageID != session?.page?.id {
            clearSelectionPreview(); selectionView?.clearSelection(); session?.selectionIDs = nil
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
            session.selectionIDs = snapshot.identity   // exactly what was tapped, not everything inside its box
            let selected = UIBezierPath(rect: snapshot.bounds)
            selected.apply(CGAffineTransform(a: self.canvas.zoomScale, b: 0, c: 0, d: self.canvas.zoomScale, tx: -self.canvas.contentOffset.x, ty: -self.canvas.contentOffset.y))
            return selected
        }
        selectionView?.selectionCompleted = { [weak self, weak session] path in
            guard let self, let session, let page = session.page else { return }
            session.selectionIDs = nil
            session.selectionIDs = session.selectionSnapshot(page, path: self.logicalPath(path)).identity
            Diagnostics.shared.record("lasso.captured", ["strokes": String(session.selectionIDs?.strokeIDs.count ?? 0), "elements": String(session.selectionIDs?.elementIDs.count ?? 0)])
        }
        selectionView?.selectionDiscarded = { [weak session] in session?.selectionIDs = nil }
        selectionView?.transformCommitted = { [weak self, weak session] path, scale, scaleY, rotation, anchor in
            guard let self, let session else { return }
            let logical = self.logicalPath(path)
            guard let overlay = self.selectionView else { return }
            let tool = session.selectedTool, generation = self.selectionGeneration
            self.selectionCommitting = true; self.selectionRendered = false
            overlay.isUserInteractionEnabled = false
            let pageAnchor = CGPoint(x: (anchor.x + self.canvas.contentOffset.x) / self.canvas.zoomScale, y: (anchor.y + self.canvas.contentOffset.y) / self.canvas.zoomScale)
            FrameMonitor.shared.end(["result": "transformed"])
            let started = CACurrentMediaTime()
            Task { @MainActor [weak self] in
                let success = await session.affineSelection(inside: logical, scale: scale, rotation: rotation, scaleY: scaleY, anchor: pageAnchor, durable: false)
                Diagnostics.shared.record("lasso.transform.commit", ["ms": elapsedMilliseconds(since: started), "success": String(success), "scale": String(format: "%.2f", scale), "rotation": String(format: "%.2f", rotation)])
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
            let snapshot = session.selectionSnapshot(page, path: self.logicalPath(path))
            guard !snapshot.containsLockedObjects, snapshot.ink.strokes.isEmpty, snapshot.elements.count == 1, let item = snapshot.elements.first else { return false }
            return (item.kind == .stickyNote || item.kind == .text) && abs(item.rotation ?? 0) < 0.001
        }
        selectionView?.menuActions = { [weak self, weak session] path in
            guard let self, let session, let page = session.page, let overlay = self.selectionView else { return [] }
            let started = CACurrentMediaTime()
            defer { Diagnostics.shared.record("lasso.menu", ["snapshotMs": elapsedMilliseconds(since: started), "pageStrokes": String(self.canvas.drawing.strokes.count)]) }
            let snapshot = session.selectionSnapshot(page, path: self.logicalPath(path))
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
            let end = Perf.begin("lasso.pickup"); defer { end() }
            let started = CACurrentMediaTime()
            self.clearSelectionPreview()
            let snapshot = session.selectionSnapshot(page, path: self.logicalPath(path))
            guard !snapshot.isEmpty, !snapshot.containsLockedObjects, self.canvas.zoomScale > 0 else {
                Diagnostics.shared.record("lasso.pickup.refused", ["empty": String(snapshot.isEmpty), "locked": String(snapshot.containsLockedObjects)]); return
            }
            let preview = SelectionDragPreview(frame: self.bounds, page: page, artwork: session.artwork,
                                               drawing: self.canvas.drawing, snapshot: snapshot,
                                               zoom: self.canvas.zoomScale, offset: self.canvas.contentOffset, asynchronous: true)
            Diagnostics.shared.record("lasso.pickup", ["mainThreadMs": elapsedMilliseconds(since: started), "strokes": String(snapshot.strokeIndices.count),
                "elements": String(snapshot.elementIDs.count), "pageStrokes": String(self.canvas.drawing.strokes.count), "zoom": String(format: "%.2f", self.canvas.zoomScale)])
            preview.onReady = { Diagnostics.shared.record("lasso.preview.ready", ["msAfterPickup": elapsedMilliseconds(since: started)]) }
            FrameMonitor.shared.begin("lasso.drag")
            self.selectionPreview = preview
            if let overlay = self.selectionView { self.insertSubview(preview, belowSubview: overlay) }
        }
        selectionView?.moveChanged = { [weak self] delta in self?.selectionPreview?.move(by: delta) ?? .zero }
        selectionView?.moveCancelled = { [weak self] in FrameMonitor.shared.end(["result": "cancelled"]); self?.clearSelectionPreview() }
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
                FrameMonitor.shared.end(["result": "moved"])
                let started = CACurrentMediaTime()
                Task { @MainActor [weak self] in
                    let success = await moved(pagePath, logicalDelta)
                    Diagnostics.shared.record("lasso.commit", ["ms": elapsedMilliseconds(since: started), "success": String(success), "strokes": String(preview?.snapshot.strokeIndices.count ?? 0)])
                    guard let self, self.selectionView === overlay, session.selectedTool == tool, self.selectionGeneration == generation, self.selectionPreview === preview else { return }
                    self.selectionCommitFinished = true
                    if !success || logicalDelta == .zero {
                        self.clearSelectionPreview()
                    } else if preview?.snapshot.ink.strokes.isEmpty != false {
                        self.paper.whenDrawn { [weak self] in
                            guard let self, self.selectionGeneration == generation, self.selectionPreview === preview else { return }
                            self.clearSelectionPreview()
                        }
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
                    let snapshot = session.selectionSnapshot(page, path: pagePath)
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
                    let snapshot = session.selectionSnapshot(page, path: pagePath)
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
        selectionView?.selectionCompleted?(path)
        selectionView?.installSelection(path)
    }
    func logicalPath(_ path: UIBezierPath) -> UIBezierPath {
        let result = UIBezierPath(cgPath: path.cgPath), zoom = canvas.zoomScale
        result.apply(CGAffineTransform(a: 1 / zoom, b: 0, c: 0, d: 1 / zoom, tx: canvas.contentOffset.x / zoom, ty: canvas.contentOffset.y / zoom))
        return result
    }
}
