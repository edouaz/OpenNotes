import UIKit

final class ImageHandlesView: UIView, UIContextMenuInteractionDelegate, UIGestureRecognizerDelegate {
    let preview = UIImageView()
    private var handles: [UIView] = []
    private let outline = CAShapeLayer()
    let deleteButton = UIButton(type: .system)
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
    private var dragStart = CGPoint.zero
    private let imageDrag = UIPanGestureRecognizer()
    init(item: PageElement, image: UIImage?) {
        self.item = item
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
        deleteButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        deleteButton.tintColor = .systemRed
        deleteButton.backgroundColor = .systemBackground; deleteButton.layer.cornerRadius = 22
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
        if gestureRecognizer is UIPanGestureRecognizer { dragStart = touch.location(in: superview) }
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
        var origin = CGPoint(x: -44, y: -44)
        if let superview {
            let viewport = convert(superview.bounds, from: superview)
            origin.x = max(origin.x, viewport.minX)
            origin.y = max(origin.y, viewport.minY)
            if CGRect(origin: origin, size: CGSize(width: 44, height: 44)).intersects(handles[0].frame) {
                origin.x = 22
            }
            origin.x = min(origin.x, viewport.maxX - 44)
            origin.y = min(origin.y, viewport.maxY - 44)
        }
        deleteButton.frame = CGRect(origin: origin, size: CGSize(width: 44, height: 44))
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
        if gesture.state == .began { initial = frame; selectImage(); Diagnostics.shared.record("image.drag.begin", ["image": item.id.uuidString]) }
        let point = gesture.location(in: superview)
        let delta = CGPoint(x: point.x - dragStart.x, y: point.y - dragStart.y)
        frame.origin = CGPoint(x: initial.minX + delta.x, y: initial.minY + delta.y)
        if gesture.state == .ended {
            Diagnostics.shared.record("image.drag.end", ["dx": String(Double(delta.x)), "dy": String(Double(delta.y)), "zoom": String(Double(zoom))])
            moveImage(by: CGPoint(x: delta.x / zoom, y: delta.y / zoom))
        } else if gesture.state == .cancelled { frame = initial; Diagnostics.shared.record("image.drag.cancel") }
    }
    func moveImage(by delta: CGPoint) {
        guard item.isLocked != true, delta.x.isFinite, delta.y.isFinite else { return }
        item.x = min(max(0, item.x + delta.x), max(0, pageSize.width - item.width))
        item.y = min(max(0, item.y + delta.y), max(0, pageSize.height - item.height))
        changed?(item)
    }
    func resizeImage(by factor: CGFloat, corner: Int = 3) {
        guard item.isLocked != true, factor.isFinite, item.width > 0, item.height > 0 else { return }
        let left = corner % 2 == 0, top = corner < 2
        let right = item.x + item.width, bottom = item.y + item.height
        let limit = min((left ? right : pageSize.width - item.x) / item.width, (top ? bottom : pageSize.height - item.y) / item.height)
        let minimum = min(44 / max(min(item.width, item.height) * zoom, 1), limit)
        let value = max(minimum, min(max(0.01, factor), limit))
        item.width *= value; item.height *= value
        if left { item.x = right - item.width }
        if top { item.y = bottom - item.height }
        changed?(item)
    }
    func resizeSide(_ side: Int, by delta: CGFloat) {
        guard item.isLocked != true, delta.isFinite else { return }
        let minimum = 44 / max(zoom, 0.01)
        switch side {
        case 4:
            let right = item.x + item.width
            item.x = min(max(0, item.x + delta), max(0, right - minimum)); item.width = right - item.x
        case 5: item.width = min(max(minimum, item.width + delta), pageSize.width - item.x)
        case 6:
            let bottom = item.y + item.height
            item.y = min(max(0, item.y + delta), max(0, bottom - minimum)); item.height = bottom - item.y
        case 7: item.height = min(max(minimum, item.height + delta), pageSize.height - item.y)
        default: return
        }
        changed?(item)
    }
    @objc private func scale(_ gesture: UIPanGestureRecognizer) {
        guard item.isLocked != true, let corner = gesture.view?.tag else { return }
        if gesture.state == .began { initial = frame; selectImage() }
        let point = gesture.location(in: superview)
        let delta = CGPoint(x: point.x - dragStart.x, y: point.y - dragStart.y)
        if corner >= 4 {
            var preview = initial
            switch corner {
            case 4: preview.origin.x += delta.x; preview.size.width -= delta.x
            case 5: preview.size.width += delta.x
            case 6: preview.origin.y += delta.y; preview.size.height -= delta.y
            default: preview.size.height += delta.y
            }
            if preview.width >= 44 && preview.height >= 44 { frame = preview }
            if gesture.state == .ended { resizeSide(corner, by: (corner < 6 ? delta.x : delta.y) / zoom) }
            else if gesture.state == .cancelled { frame = initial }
            return
        }
        let dx = corner % 2 == 0 ? -delta.x : delta.x, dy = corner < 2 ? -delta.y : delta.y
        let factor = max(0.01, 1 + (dx * initial.width + dy * initial.height) / max(1, initial.width * initial.width + initial.height * initial.height))
        let size = CGSize(width: initial.width * factor, height: initial.height * factor)
        frame = CGRect(x: corner % 2 == 0 ? initial.maxX - size.width : initial.minX, y: corner < 2 ? initial.maxY - size.height : initial.minY, width: size.width, height: size.height)
        if gesture.state == .ended { resizeImage(by: factor, corner: corner) }
        else if gesture.state == .cancelled { frame = initial }
    }
}
