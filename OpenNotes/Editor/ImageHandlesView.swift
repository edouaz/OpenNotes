import UIKit

final class ImageHandlesView: UIView, UIContextMenuInteractionDelegate, UIGestureRecognizerDelegate {
    let preview = UIImageView()
    private var handles: [UIView] = []
    private let outline = CAShapeLayer()
    let deleteButton = UIButton(type: .system)
    private let deleteBadge = UIView()
    var item: PageElement
    var zoom: CGFloat = 1
    var pageSize = CGSize.zero
    var changed: ((PageElement?) -> Void)?
    var selected: (() -> Void)?
    var editableWithPencil = true
    var editsDirectly = true
    var showsHandles = true {
        didSet {
            handles.forEach { $0.isHidden = !showsHandles }
            outline.isHidden = !showsHandles; deleteButton.isHidden = !showsHandles
            accessibilityValue = showsHandles ? "Selected" : nil
        }
    }
    private var initial = CGRect.zero
    private var start: PageElement
    private let imageDrag = UIPanGestureRecognizer()
    init(item: PageElement, image: UIImage?) {
        self.item = item; self.start = item
        super.init(frame: .zero)
        preview.image = image; preview.contentMode = .scaleToFill; preview.isUserInteractionEnabled = false
        addSubview(preview)
        outline.fillColor = UIColor.clear.cgColor; outline.strokeColor = UIColor.systemTeal.cgColor
        outline.lineWidth = 2; outline.lineDashPattern = [6, 4]; layer.addSublayer(outline)
        imageDrag.addTarget(self, action: #selector(dragImage(_:)))
        imageDrag.maximumNumberOfTouches = 1; imageDrag.delegate = self; addGestureRecognizer(imageDrag)
        for corner in 0..<8 {
            let handle = UIView(); handle.tag = corner
            let dot = UIView(frame: CGRect(x: 16, y: 16, width: 12, height: 12))
            dot.backgroundColor = .white; dot.layer.cornerRadius = 6
            dot.layer.borderWidth = 2; dot.layer.borderColor = UIColor.systemTeal.cgColor
            dot.isUserInteractionEnabled = false; handle.addSubview(dot)
            handle.accessibilityLabel = corner < 4 ? "Resize image, corner \(corner + 1)" : "Resize image, side \(corner - 3)"
            let pan = UIPanGestureRecognizer(target: self, action: #selector(scale(_:)))
            pan.delegate = self
            handle.addGestureRecognizer(pan)
            handles.append(handle); addSubview(handle)
        }
        deleteBadge.backgroundColor = UIColor.white.withAlphaComponent(0.95)
        deleteBadge.layer.cornerRadius = 11; deleteBadge.isUserInteractionEnabled = false
        deleteBadge.layer.shadowColor = UIColor.black.cgColor; deleteBadge.layer.shadowOpacity = 0.2; deleteBadge.layer.shadowRadius = 2; deleteBadge.layer.shadowOffset = CGSize(width: 0, height: 1)
        deleteButton.addSubview(deleteBadge)
        deleteButton.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .heavy)), for: .normal)
        deleteButton.tintColor = .systemRed
        if let image = deleteButton.imageView { deleteButton.bringSubviewToFront(image) }
        deleteButton.accessibilityLabel = "Delete image"
        deleteButton.accessibilityIdentifier = "image.delete"
        deleteButton.addTarget(self, action: #selector(deleteImage), for: .touchUpInside)
        addSubview(deleteButton)
        let tap = UITapGestureRecognizer(target: self, action: #selector(selectImage))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
        addInteraction(UIContextMenuInteraction(delegate: self))
        isAccessibilityElement = true
        accessibilityLabel = "Image"
        accessibilityIdentifier = "image.\(item.id)"
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Delete") { [weak self] _ in if self?.item.isLocked != true { self?.changed?(nil) }; return true },
            UIAccessibilityCustomAction(name: "Copy image") { [weak self] _ in UIPasteboard.general.image = self?.preview.image; return true },
            UIAccessibilityCustomAction(name: "Move left") { [weak self] _ in self?.moveImage(by: CGPoint(x: -20, y: 0)); return true },
            UIAccessibilityCustomAction(name: "Move right") { [weak self] _ in self?.moveImage(by: CGPoint(x: 20, y: 0)); return true },
            UIAccessibilityCustomAction(name: "Move up") { [weak self] _ in self?.moveImage(by: CGPoint(x: 0, y: -20)); return true },
            UIAccessibilityCustomAction(name: "Move down") { [weak self] _ in self?.moveImage(by: CGPoint(x: 0, y: 20)); return true },
            UIAccessibilityCustomAction(name: "Enlarge") { [weak self] _ in self?.resizeImage(by: 1.1); return true },
            UIAccessibilityCustomAction(name: "Reduce") { [weak self] _ in self?.resizeImage(by: 0.9); return true }
        ]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func accessibilityActivate() -> Bool { selectImage(); return true }
    func acceptsImageDrag(at point: CGPoint) -> Bool {
        !showsHandles || (!handles.contains { $0.frame.contains(point) } && !deleteButton.frame.contains(point))
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === imageDrag, !acceptsImageDrag(at: touch.location(in: self)) { return false }
        return true
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if !editableWithPencil, event?.allTouches?.contains(where: { $0.type == .pencil }) == true { return nil }
        return super.hitTest(point, with: event)
    }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.contains(point) || (showsHandles && (handles.contains { $0.frame.contains(point) } || deleteButton.frame.contains(point)))
    }
    override func layoutSubviews() {
        super.layoutSubviews(); preview.frame = bounds
        outline.path = UIBezierPath(rect: bounds).cgPath
        for (corner, handle) in handles.enumerated() {
            let centers = [CGPoint(x: 0, y: 0), CGPoint(x: bounds.width, y: 0), CGPoint(x: 0, y: bounds.height), CGPoint(x: bounds.width, y: bounds.height),
                           CGPoint(x: 0, y: bounds.midY), CGPoint(x: bounds.width, y: bounds.midY), CGPoint(x: bounds.midX, y: 0), CGPoint(x: bounds.midX, y: bounds.height)]
            handle.frame = CGRect(x: centers[corner].x - 22, y: centers[corner].y - 22, width: 44, height: 44)
        }
        // Outside the image, above or below a corner, clear of every 44 pt handle; the first spot inside the viewport wins.
        let w = bounds.width, h = bounds.height
        let spots = [CGPoint(x: w + 2, y: -68), CGPoint(x: -46, y: -68), CGPoint(x: w + 2, y: h + 24), CGPoint(x: -46, y: h + 24)]
        var origin = spots[0]
        if let superview {
            let viewport = convert(superview.bounds, from: superview)
            origin = spots.first { viewport.contains(CGRect(origin: $0, size: CGSize(width: 44, height: 44))) } ?? spots[0]
        }
        deleteButton.frame = CGRect(origin: origin, size: CGSize(width: 44, height: 44))
        deleteBadge.frame = CGRect(x: 11, y: 11, width: 22, height: 22); deleteBadge.layer.shadowPath = UIBezierPath(ovalIn: deleteBadge.bounds).cgPath
    }
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(title: "Copy image", image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.image = self?.preview.image },
                UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: self?.item.isLocked == true ? [.destructive, .disabled] : .destructive) { _ in if self?.item.isLocked != true { self?.changed?(nil) } }
            ])
        }
    }
    @objc private func selectImage() { showsHandles = true; selected?() }
    @objc private func deleteImage() { if item.isLocked != true { changed?(nil) } }
    @objc private func dragImage(_ gesture: UIPanGestureRecognizer) {
        guard editsDirectly else { if gesture.state == .began { selected?() }; return }
        guard item.isLocked != true else { return }
        if gesture.state == .began { begin("image.drag"); Diagnostics.shared.record("image.drag.begin", ["image": item.id.uuidString]) }
        let t = gesture.translation(in: superview)
        let proposed = Self.moved(start, by: CGPoint(x: t.x / zoom, y: t.y / zoom), page: pageSize)
        finish(gesture, proposed: proposed, event: "image.drag")
    }
    @objc private func scale(_ gesture: UIPanGestureRecognizer) {
        guard item.isLocked != true, let corner = gesture.view?.tag else { return }
        if gesture.state == .began { begin("image.resize") }
        let t = gesture.translation(in: superview)
        let proposed: PageElement
        if corner >= 4 {
            proposed = Self.sided(start, side: corner, by: (corner < 6 ? t.x : t.y) / zoom, page: pageSize, zoom: zoom)
        } else {
            // Project the drag on the diagonal so the opposite corner stays put and the aspect ratio holds.
            let dx = corner % 2 == 0 ? -t.x : t.x, dy = corner < 2 ? -t.y : t.y
            let factor = 1 + (dx * initial.width + dy * initial.height) / max(1, initial.width * initial.width + initial.height * initial.height)
            proposed = Self.scaled(start, by: factor, corner: corner, page: pageSize, zoom: zoom)
        }
        finish(gesture, proposed: proposed, event: "image.resize")
    }
    private func begin(_ monitor: String) {
        start = item; initial = unrotatedFrame; selectImage(); FrameMonitor.shared.begin(monitor)
    }
    /// The live frame is the exact clamped result that will be saved, so nothing jumps on release.
    private func finish(_ gesture: UIPanGestureRecognizer, proposed: PageElement, event: String) {
        switch gesture.state {
        case .began, .changed: show(proposed)
        case .ended:
            FrameMonitor.shared.end()
            show(proposed)
            Diagnostics.shared.record("\(event).end", ["dx": String(Double(proposed.x - start.x)), "dy": String(Double(proposed.y - start.y)),
                                                       "w": String(Double(proposed.width)), "h": String(Double(proposed.height)), "zoom": String(Double(zoom))])
            if proposed != start { item = proposed; changed?(proposed) }
        default:
            FrameMonitor.shared.end(); show(start); Diagnostics.shared.record("\(event).cancel")
        }
    }
    private func show(_ proposed: PageElement) {
        place(CGRect(x: initial.minX + (proposed.x - start.x) * zoom, y: initial.minY + (proposed.y - start.y) * zoom,
                     width: proposed.width * zoom, height: proposed.height * zoom))
    }
    func moveImage(by delta: CGPoint) {
        guard item.isLocked != true else { return }
        item = Self.moved(item, by: delta, page: pageSize); changed?(item)
    }
    func resizeImage(by factor: CGFloat, corner: Int = 3) {
        guard item.isLocked != true else { return }
        item = Self.scaled(item, by: factor, corner: corner, page: pageSize, zoom: zoom); changed?(item)
    }
    func resizeSide(_ side: Int, by delta: CGFloat) {
        guard item.isLocked != true else { return }
        item = Self.sided(item, side: side, by: delta, page: pageSize, zoom: zoom); changed?(item)
    }
    static func moved(_ source: PageElement, by delta: CGPoint, page: CGSize) -> PageElement {
        guard delta.x.isFinite, delta.y.isFinite else { return source }
        var item = source
        item.x = min(max(0, item.x + delta.x), max(0, page.width - item.width))
        item.y = min(max(0, item.y + delta.y), max(0, page.height - item.height))
        return item
    }
    static func scaled(_ source: PageElement, by factor: CGFloat, corner: Int, page: CGSize, zoom: CGFloat) -> PageElement {
        guard factor.isFinite, source.width > 0, source.height > 0 else { return source }
        var item = source
        let left = corner % 2 == 0, top = corner < 2
        let right = item.x + item.width, bottom = item.y + item.height
        let limit = min((left ? right : page.width - item.x) / item.width, (top ? bottom : page.height - item.y) / item.height)
        let minimum = min(44 / max(min(item.width, item.height) * zoom, 1), limit)
        let value = max(minimum, min(max(0.01, factor), limit))
        item.width *= value; item.height *= value
        if left { item.x = right - item.width }
        if top { item.y = bottom - item.height }
        return item
    }
    static func sided(_ source: PageElement, side: Int, by delta: CGFloat, page: CGSize, zoom: CGFloat) -> PageElement {
        guard delta.isFinite else { return source }
        var item = source
        let minimum = 44 / max(zoom, 0.01)
        switch side {
        case 4:
            let right = item.x + item.width
            item.x = min(max(0, item.x + delta), max(0, right - minimum)); item.width = right - item.x
        case 5: item.width = min(max(minimum, item.width + delta), page.width - item.x)
        case 6:
            let bottom = item.y + item.height
            item.y = min(max(0, item.y + delta), max(0, bottom - minimum)); item.height = bottom - item.y
        case 7: item.height = min(max(minimum, item.height + delta), page.height - item.y)
        default: break
        }
        return item
    }
    private var unrotatedFrame: CGRect { CGRect(x: center.x - bounds.width / 2, y: center.y - bounds.height / 2, width: bounds.width, height: bounds.height) }
    private func place(_ rect: CGRect) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        bounds.size = rect.size; center = CGPoint(x: rect.midX, y: rect.midY)
        CATransaction.commit()
    }
}
