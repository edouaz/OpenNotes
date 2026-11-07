import SwiftUI
import UIKit

// Fit, pinch zoom, saved position, bounds and background alignment.
extension PageScrollView {
    func showSearchHighlights(_ rects: [CGRect]) { guard searchRects != rects else { return }; searchRects = rects; alignBackground() }
    func configurePaper(page: NotePage, artwork: PageArtwork?) {
        var rendered = page
        if let id = editingInlineNoteID, let index = rendered.elements?.firstIndex(where: { $0.id == id }) {
            rendered.elements?[index].text = ""
            rendered.elements?[index].richTextRTF = nil
        }
        if editingImages { rendered.elements?.removeAll { $0.kind == .image } }
        paper.configure(page: rendered, artwork: artwork)
    }
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
    @objc func doubleTap(_ gesture: UITapGestureRecognizer) {
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
    @objc func panOverNote(_ pan: UIPanGestureRecognizer) {
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

    @objc func pinchChanged(_ pinch: UIPinchGestureRecognizer) {
        // The parent receives touches over images too; the native canvas owns ink rendering.
        let location = pinch.location(in: self)
        if pinch.state == .began {
            Diagnostics.shared.record("zoom.begin", ["scale": String(Double(canvas.zoomScale))])
            FrameMonitor.shared.begin("zoom")
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
            FrameMonitor.shared.end()
            pinchOrigin = nil; alignBackground(); savePosition()
        }
    }
    func boundedOffset(_ proposed: CGPoint) -> CGPoint {
        let minimum = CGPoint(x: -canvas.contentInset.left, y: -canvas.contentInset.top)
        return CGPoint(
            x: min(max(minimum.x, proposed.x), max(minimum.x, pageSize.width * canvas.zoomScale - bounds.width + canvas.contentInset.right)),
            y: min(max(minimum.y, proposed.y), max(minimum.y, pageSize.height * canvas.zoomScale - bounds.height + canvas.contentInset.bottom)))
    }
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
