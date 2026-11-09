import UIKit
import UIKit.UIGestureRecognizerSubclass

class StickyDragPan: UIPanGestureRecognizer {
    private var startPoint: CGPoint?

    func recordInitialTouch(_ touch: UITouch) { startPoint = touch.location(in: nil) }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if startPoint == nil, let touch = touches.first { recordInitialTouch(touch) }
        super.touchesBegan(touches, with: event)
    }

    func translationFromInitialTouch(in view: UIView?) -> CGPoint {
        guard let startPoint else { return translation(in: view) }
        let initial = view?.convert(startPoint, from: nil) ?? startPoint
        let current = location(in: view)
        return CGPoint(x: current.x - initial.x, y: current.y - initial.y)
    }

    override func reset() { startPoint = nil; super.reset() }
}

private final class StickyNoteAccessibilityElement: UIAccessibilityElement {
    var activate: (() -> Bool)?
    override func accessibilityActivate() -> Bool { activate?() ?? false }
}

final class StickyNoteControl: UIButton, UITextViewDelegate, UIGestureRecognizerDelegate {
    var item: PageElement
    var zoom: CGFloat = 1
    var pageSize = CGSize.zero
    var changed: ((PageElement?) -> Void)?
    var edit: (() -> Void)?
    var contextualAction: ((PageSelectionAction) -> Void)?
    private(set) var isObjectSelected = false
    var allowsBodySelection = true { didSet { updateControls() } }
    override var isUserInteractionEnabled: Bool { didSet { updateControls() } }
    var canManipulate = true { didSet { updateControls() } }
    var movementBounds: CGRect?
    var selectionChanged: ((Bool) -> Void)?
    var inlineEditingChanged: ((Bool) -> Void)?
    var draftChanged: ((PageElement) -> Void)?
    var movePreviewBegan: (() -> Void)?
    var movePreviewChanged: ((CGPoint) -> Void)?
    var movePreviewCancelled: (() -> Void)?
    var resizePreviewBegan: (() -> Void)?
    var resizePreviewChanged: ((CGSize) -> Void)?
    var resizePreviewPositionChanged: ((CGPoint) -> Void)?
    var resizePreviewCancelled: (() -> Void)?
    let collapseButton = UIButton(type: .system)   // chevron in the header
    let deleteButton = UIButton(type: .system)     // small red cross, shown while selected
    private let deleteBadge = UIView()
    let resizeHandle = UIView()           // bottom-right corner
    private(set) var cornerHandles: [UIView] = []   // top-left, top-right, bottom-left
    var allResizeHandles: [UIView] { cornerHandles + [resizeHandle] }
    private var initialSize = CGSize.zero
    private var initialCenter = CGPoint.zero
    private lazy var bodyAccessibility = StickyNoteAccessibilityElement(accessibilityContainer: self)
    private var compactControls = false
    private var textEditor: UITextView?
    private var editingZoom: CGFloat = 1   // fonts are scaled by this for the editor's whole lifetime, whatever the viewport does
    var isEditingInline: Bool { textEditor != nil }
    init(item: PageElement) {
        self.item = item
        super.init(frame: .zero)
        backgroundColor = .clear
        contentHorizontalAlignment = .left; contentVerticalAlignment = .top
        contentEdgeInsets = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        setTitle(nil, for: .normal)
        setTitleColor(.black, for: .normal)
        titleLabel?.numberOfLines = 0; titleLabel?.font = .systemFont(ofSize: 16)
        titleLabel?.adjustsFontForContentSizeCategory = true
        accessibilityLabel = "Sticky note: \(item.text)"
        accessibilityValue = item.collapsed == true ? "Collapsed" : "Expanded"
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: item.collapsed == true ? "Expand" : "Collapse") { [weak self] _ in self?.toggleCollapsed(); return true }]
        collapseButton.setImage(UIImage(systemName: "chevron.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)), for: .normal)
        collapseButton.tintColor = UIColor(white: 0.25, alpha: 0.55); collapseButton.accessibilityLabel = "Collapse sticky note"
        collapseButton.accessibilityIdentifier = "sticky.collapse"
        collapseButton.addTarget(self, action: #selector(toggleCollapsed), for: .touchUpInside)
        collapseButton.isHidden = true
        addSubview(collapseButton)
        // Corners: 0 top-left, 1 top-right, 2 bottom-left, 3 bottom-right (the legacy `resizeHandle`).
        for corner in 0..<4 {
            let handle = corner == 3 ? resizeHandle : UIView()
            handle.tag = corner
            handle.addSubview(StickyCornerGrip(corner: corner)); handle.isHidden = true
            handle.isAccessibilityElement = true; handle.accessibilityLabel = "Resize sticky note"
            let resizePan = StickyDragPan(target: self, action: #selector(resize(_:)))
            configure(resizePan); handle.addGestureRecognizer(resizePan)
            addSubview(handle)
            if corner != 3 { cornerHandles.append(handle) }
        }
        deleteBadge.backgroundColor = UIColor.white.withAlphaComponent(0.92)
        deleteBadge.layer.cornerRadius = 9; deleteBadge.isUserInteractionEnabled = false
        deleteBadge.layer.shadowColor = UIColor.black.cgColor; deleteBadge.layer.shadowOpacity = 0.18; deleteBadge.layer.shadowRadius = 1.5; deleteBadge.layer.shadowOffset = CGSize(width: 0, height: 0.5)
        deleteButton.addSubview(deleteBadge)
        deleteButton.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .heavy)), for: .normal)
        deleteButton.tintColor = .systemRed
        deleteButton.accessibilityLabel = "Delete sticky note"; deleteButton.accessibilityIdentifier = "sticky.delete"
        deleteButton.addTarget(self, action: #selector(deleteNote), for: .touchUpInside)
        deleteButton.isHidden = true
        addSubview(deleteButton)
        if let image = deleteButton.imageView { deleteButton.bringSubviewToFront(image) }
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapBody))
        configure(tap); addGestureRecognizer(tap)
        let pan = StickyDragPan(target: self, action: #selector(drag(_:)))
        configure(pan); addGestureRecognizer(pan)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(dragCollapsed(_:)))
        configure(hold); addGestureRecognizer(hold)
        tap.require(toFail: hold)
        menu = UIMenu(children: [
            UIAction(title: "Edit Text", image: UIImage(systemName: "text.cursor")) { [weak self] _ in self?.beginInlineEditing() },
            UIAction(title: "Customize…", image: UIImage(systemName: "paintpalette")) { [weak self] _ in self?.edit?() },
            UIAction(title: item.collapsed == true ? "Expand" : "Collapse", image: UIImage(systemName: "rectangle.compress.vertical")) { [weak self] _ in
                self?.toggleCollapsed()
            },
            UIAction(title: "Duplicate", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in self?.contextualAction?(.duplicateSelection) },
            UIMenu(title: "Arrange", image: UIImage(systemName: "square.3.layers.3d"), children: [
                UIAction(title: "Bring to Front") { [weak self] _ in self?.contextualAction?(.bringFront) },
                UIAction(title: "Send to Back") { [weak self] _ in self?.contextualAction?(.sendBack) }
            ]),
            UIAction(title: "Lock", image: UIImage(systemName: "lock")) { [weak self] _ in self?.contextualAction?(.lockSelection) },
            UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in Diagnostics.shared.record("sticky.delete", ["source": "menu"]); self?.changed?(nil) }
        ])
        if item.isLocked == true {
            menu = UIMenu(children: [UIAction(title: "Unlock", image: UIImage(systemName: "lock.open")) { [weak self] _ in
                guard let self else { return }
                if let action = self.contextualAction { action(.lockSelection) }
                else { self.item.isLocked = false; self.changed?(self.item) }
            }])
            showsMenuAsPrimaryAction = true
        }
        if item.collapsed == true && item.isLocked != true { menu = nil }
        isAccessibilityElement = false
        bodyAccessibility.accessibilityTraits = .button
        bodyAccessibility.accessibilityIdentifier = "sticky.\(item.id)"
        bodyAccessibility.activate = { [weak self] in
            guard let self, self.item.isLocked != true else { return false }
            if self.item.collapsed == true { self.toggleCollapsed() } else { self.setObjectSelected(true) }
            return true
        }
        accessibilityElements = [bodyAccessibility]
        updateControls()
    }
    private func configure(_ gesture: UIGestureRecognizer) {
        gesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        gesture.delegate = self
        if let pan = gesture as? UIPanGestureRecognizer { pan.maximumNumberOfTouches = 1 }
        if let hold = gesture as? UILongPressGestureRecognizer { hold.numberOfTouchesRequired = 1 }
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard touch.type == .direct, textEditor == nil else { return false }
        if gestureRecognizer.view === self, touch.view !== self, !(gestureRecognizer is UILongPressGestureRecognizer && item.collapsed == true) { return false }
        if gestureRecognizer is UIPanGestureRecognizer || gestureRecognizer is UILongPressGestureRecognizer {
            guard canManipulate, item.isLocked != true else { return false }
        }
        if gestureRecognizer is UILongPressGestureRecognizer { return item.collapsed == true }
        if gestureRecognizer is UIPanGestureRecognizer, gestureRecognizer.view === self { return item.collapsed != true && isObjectSelected && item.isLocked != true }
        return true
    }
    func setObjectSelected(_ selected: Bool) {
        let selected = selected && item.isLocked != true && item.collapsed != true
        guard isObjectSelected != selected else { return }
        isObjectSelected = selected
        updateControls()
        setNeedsLayout()
        selectionChanged?(selected)
    }
    private func updateControls() {
        let expanded = item.collapsed != true && item.isLocked != true && textEditor == nil
        let showsHandles = expanded && isObjectSelected && canManipulate
        resizeHandle.isHidden = !showsHandles
        cornerHandles.forEach { $0.isHidden = !showsHandles || compactControls }
        if showsHandles, !UIAccessibility.isReduceMotionEnabled {
            allResizeHandles.forEach { $0.alpha = 0 }
            UIView.animate(withDuration: 0.15) { self.allResizeHandles.forEach { $0.alpha = 1 } }
        } else { allResizeHandles.forEach { $0.alpha = 1 } }
        // Chevron: one tap collapses. Not while finger-drawing owns the page, read-only, or locked.
        // Small notes keep their whole body as the drag target; use the actions menu there.
        // Only on the selected note: unselected notes carry no chrome, so a Pencil stroke can start anywhere on them.
        collapseButton.isHidden = !(expanded && isObjectSelected && canManipulate && allowsBodySelection && isUserInteractionEnabled) || compactControls
        deleteButton.isHidden = !showsHandles || compactControls
        accessibilityElements = [bodyAccessibility] + [collapseButton, deleteButton].filter { !$0.isHidden } + allResizeHandles.filter { !$0.isHidden }
        updateAccessibilityActions()
    }
    private func updateAccessibilityActions() {
        bodyAccessibility.accessibilityLabel = "Sticky note: \(item.text)"
        bodyAccessibility.accessibilityValue = item.collapsed == true ? "Collapsed" : (isObjectSelected ? "Selected" : "Expanded")
        if item.isLocked == true {
            bodyAccessibility.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Unlock") { [weak self] _ in
                guard let self else { return false }
                if let action = self.contextualAction { action(.lockSelection) }
                else { self.item.isLocked = false; self.changed?(self.item) }
                return true
            }]
            return
        }
        bodyAccessibility.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: item.collapsed == true ? "Expand" : "Collapse") { [weak self] _ in self?.toggleCollapsed(); return true },
            UIAccessibilityCustomAction(name: "Select") { [weak self] _ in self?.setObjectSelected(true); return true },
            UIAccessibilityCustomAction(name: "Edit text") { [weak self] _ in self?.beginInlineEditing(); return true }
        ]
    }
    func bodyContains(_ point: CGPoint) -> Bool {
        item.collapsed != true && UIBezierPath(roundedRect: bounds, cornerRadius: item.stickyRadius * max(zoom, 0.01)).contains(point)
    }
    var canDragBody: Bool { item.collapsed != true && isObjectSelected && item.isLocked != true && canManipulate && textEditor == nil }
    /// Tap on the body, delivered by the page: select, then edit text on a second tap.
    func tapBodyFromPage() { tapBody() }
    @objc private func tapBody() {
        if item.collapsed == true { toggleCollapsed() }
        else if isObjectSelected { beginInlineEditing() }
        else if allowsBodySelection { setObjectSelected(true) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // The resize grips sit just outside the corners, so a selected note answers a little beyond its body.
        if compactControls && isObjectSelected { return bounds.insetBy(dx: -44, dy: 0).contains(point) }
        if isObjectSelected { return bounds.insetBy(dx: -14, dy: -14).contains(point) || (!deleteButton.isHidden && deleteButton.frame.contains(point)) }
        return super.point(inside: point, with: event)
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        // An open note's body belongs to the page: Pencil and highlighter write on it, fingers scroll over it, and
        // PageScrollView turns taps, drags and long presses on it into note actions (`bodyContains`). The touch type
        // cannot be read reliably during hit-testing (iPadOS 16), so nothing here depends on it.
        if hit === self, item.collapsed != true { return nil }
        if hit === self, !UIBezierPath(roundedRect: bounds, cornerRadius: item.stickyRadius * max(zoom, 0.01)).contains(point) { return nil }
        return hit
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        textEditor?.frame = bounds
        let compact = (bounds.width < 88 || bounds.height < 88) && item.collapsed != true
        if compactControls != compact { compactControls = compact; updateControls() }
        bodyAccessibility.accessibilityFrameInContainerSpace = isObjectSelected
            ? bounds.insetBy(dx: min(44, bounds.width / 3), dy: min(44, bounds.height / 3)) : bounds
        let bottom = max(0, bounds.height - 44)
        // Header chevron, centred; the red cross straddles the top edge above it, far from every grip.
        let crossCenter: CGFloat = -11
        collapseButton.frame = CGRect(x: max(0, bounds.width / 2 - 22), y: crossCenter + 22, width: 44, height: 25)
        collapseButton.contentVerticalAlignment = .top; collapseButton.contentEdgeInsets = UIEdgeInsets(top: 1, left: 0, bottom: 0, right: 0)
        deleteButton.frame = CGRect(x: bounds.width / 2 - 22, y: crossCenter - 22, width: 44, height: 44)
        deleteBadge.frame = CGRect(x: 13, y: 13, width: 18, height: 18); deleteBadge.layer.shadowPath = UIBezierPath(ovalIn: deleteBadge.bounds).cgPath
        // The bracket glyph sits 9 pt into its 44 pt cell, so these origins put each grip 5 pt outside its corner.
        let outside: CGFloat = 14, inside: CGFloat = 30
        // Small notes: the single grip moves fully outside so it never covers the body's drag target.
        resizeHandle.frame = compactControls ? CGRect(x: bounds.width, y: bottom, width: 44, height: 44)
                                             : CGRect(x: bounds.width - inside, y: bounds.height - inside, width: 44, height: 44)
        if cornerHandles.count == 3 {
            cornerHandles[0].frame = CGRect(x: -outside, y: -outside, width: 44, height: 44)
            cornerHandles[1].frame = CGRect(x: bounds.width - inside, y: -outside, width: 44, height: 44)
            cornerHandles[2].frame = CGRect(x: -outside, y: bounds.height - inside, width: 44, height: 44)
        }
    }
    @objc private func deleteNote() {
        guard item.isLocked != true, canManipulate else { return }
        Diagnostics.shared.record("sticky.delete", ["source": "cross"]); changed?(nil)
    }
    @objc func toggleCollapsed() { guard item.isLocked != true else { return }; item.collapsed = !(item.collapsed ?? false); setObjectSelected(false); changed?(item) }
    func resizeNote(to size: CGSize) {
        guard canManipulate, item.isLocked != true else { return }
        item.width = min(max(88 / max(zoom, 0.01), size.width), pageSize.width - item.x)
        item.height = min(max(88 / max(zoom, 0.01), size.height), pageSize.height - item.y)
        changed?(item)
    }
    // The opposite rotated corner stays fixed as the note's model center moves.
    func resizedItem(to requested: CGSize, anchoredOpposite corner: Int = 3) -> PageElement {
        let sx: CGFloat = corner % 2 == 0 ? -1 : 1, sy: CGFloat = corner < 2 ? -1 : 1
        let minimum = 88 / max(zoom, 0.01)
        let width = max(min(item.width, minimum), requested.width), height = max(min(item.height, minimum), requested.height)
        let rotation = CGAffineTransform(rotationAngle: item.rotation ?? 0)
        func result(_ fraction: CGFloat) -> PageElement {
            var updated = item
            updated.width = item.width + (width - item.width) * fraction
            updated.height = item.height + (height - item.height) * fraction
            let dw = updated.width - item.width, dh = updated.height - item.height
            let shift = CGPoint(x: sx * dw / 2, y: sy * dh / 2).applying(rotation)
            updated.x = item.x + shift.x - dw / 2
            updated.y = item.y + shift.y - dh / 2
            return updated
        }
        func fits(_ note: PageElement) -> Bool {
            note.x >= 0 && note.y >= 0 && note.x + note.width <= pageSize.width && note.y + note.height <= pageSize.height
        }
        let candidate = result(1)
        guard !fits(candidate), fits(item) else { return candidate }
        var low: CGFloat = 0, high: CGFloat = 1
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if fits(result(mid)) { low = mid } else { high = mid }
        }
        return result(low)
    }
    private(set) var isResizing = false
    @objc private func resize(_ pan: UIPanGestureRecognizer) {
        guard canManipulate, item.isLocked != true else { return }
        isResizing = pan.state == .began || pan.state == .changed
        if pan.state == .began { initialSize = bounds.size; initialCenter = center; resizePreviewBegan?() }
        let scale = max(zoom, 0.01)
        let translation = (pan as? StickyDragPan)?.translationFromInitialTouch(in: superview) ?? pan.translation(in: superview)
        let delta = translation.applying(CGAffineTransform(rotationAngle: -(item.rotation ?? 0)))
        let corner = pan.view?.tag ?? 3
        let sx: CGFloat = corner % 2 == 0 ? -1 : 1, sy: CGFloat = corner < 2 ? -1 : 1
        let updated = delta == .zero ? item : resizedItem(to: CGSize(width: item.width + sx * delta.x / scale, height: item.height + sy * delta.y / scale), anchoredOpposite: corner)
        if pan.state == .changed {
            resizePreviewChanged?(CGSize(width: updated.width, height: updated.height))
            resizePreviewPositionChanged?(CGPoint(x: updated.x, y: updated.y))
            bounds.size = CGSize(width: max(44, updated.width * scale), height: max(44, updated.height * scale))
            let shift = CGPoint(x: (updated.x - item.x + (updated.width - item.width) / 2) * scale,
                                y: (updated.y - item.y + (updated.height - item.height) / 2) * scale)
            center = CGPoint(x: initialCenter.x + shift.x, y: initialCenter.y + shift.y)
        }
        if pan.state == .ended {
            Diagnostics.shared.record("sticky.resize", ["corner": String(corner)])
            if updated != item { item = updated; changed?(item) }
            else { bounds.size = initialSize; center = initialCenter; resizePreviewCancelled?() }
        } else if pan.state == .cancelled || pan.state == .failed {
            bounds.size = initialSize; center = initialCenter; resizePreviewCancelled?()
        }
    }
    func beginInlineEditing() {
        guard item.isLocked != true, item.collapsed != true, textEditor == nil else { return }
            editingZoom = zoom
            let editor = UITextView(frame: bounds)
            let text = NSMutableAttributedString(attributedString: RichTextDocument.attributed(item))
            text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                if let font = value as? UIFont { text.addAttribute(.font, value: font.withSize(font.pointSize * zoom), range: range) }
            }
            editor.attributedText = text
            editor.typingAttributes = [.font: UIFont.systemFont(ofSize: 16 * zoom), .foregroundColor: UIColor.black]
            editor.backgroundColor = .clear
            editor.layer.cornerRadius = item.stickyRadius * max(zoom, 0.01)
            editor.clipsToBounds = true
            editor.textContainerInset = UIEdgeInsets(top: 8 * zoom, left: 8 * zoom, bottom: 8 * zoom, right: 8 * zoom)
            editor.textContainer.lineFragmentPadding = 0
            editor.delegate = self
            editor.accessibilityLabel = "Sticky note text"
            let toolbar = UIToolbar(); toolbar.sizeToFit()
            toolbar.items = [UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil), UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(finishInlineEditing))]
            editor.inputAccessoryView = toolbar
            textEditor = editor; addSubview(editor)
            accessibilityElements = [editor]
            allResizeHandles.forEach { $0.isHidden = true }
            inlineEditingChanged?(true)
            editor.becomeFirstResponder()
    }
    func endInlineEditing() { finishInlineEditing() }
    @objc private func finishInlineEditing() {
        guard let editor = textEditor else { return }
        if editor.isFirstResponder { editor.resignFirstResponder() }
        else { textViewDidEndEditing(editor) }
    }
    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow == nil { finishInlineEditing() }
        super.willMove(toWindow: newWindow)
    }
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        textView.attributedText.length - range.length + (text as NSString).length <= 100_000
    }
    private func draft(from textView: UITextView) -> PageElement? {
        let text = NSMutableAttributedString(attributedString: textView.attributedText)
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let font = value as? UIFont { text.addAttribute(.font, value: font.withSize(min(96, max(8, font.pointSize / max(editingZoom, 0.01)))), range: range) }
        }
        guard let data = try? RichTextDocument.encode(text) else { return nil }
        var updated = item
        updated.richTextRTF = data; updated.text = text.string
        return updated
    }
    func textViewDidChange(_ textView: UITextView) {
        guard item.isLocked != true, let updated = draft(from: textView) else { return }
        draftChanged?(updated)
    }
    func textViewDidEndEditing(_ textView: UITextView) {
        guard textEditor === textView else { return }
        textEditor = nil
        accessibilityElements = [bodyAccessibility]
        inlineEditingChanged?(false)
        textView.removeFromSuperview()
        updateControls()
        guard item.isLocked != true, let updated = draft(from: textView), updated != item else { return }
        item = updated
        draftChanged?(updated)
        changed?(item)
    }
    func clampedTranslation(_ delta: CGPoint) -> CGPoint {
        let scale = max(zoom, 0.01)
        let own = CGRect(x: item.x, y: item.y, width: item.width, height: item.height)
        let group = movementBounds.map { own.union($0) } ?? own
        func clamp(_ requested: CGFloat, minEdge: CGFloat, maxEdge: CGFloat, pageEdge: CGFloat) -> CGFloat {
            let lower = -minEdge, upper = pageEdge - maxEdge
            return lower <= upper ? min(max(requested, lower), upper) : 0
        }
        return CGPoint(x: clamp(delta.x / scale, minEdge: group.minX, maxEdge: group.maxX, pageEdge: pageSize.width) * scale,
                       y: clamp(delta.y / scale, minEdge: group.minY, maxEdge: group.maxY, pageEdge: pageSize.height) * scale)
    }
    private func move(state: UIGestureRecognizer.State, delta: CGPoint) {
        guard canManipulate, item.isLocked != true, textEditor == nil else { return }
        let delta = clampedTranslation(delta)
        if state == .began { movePreviewBegan?() }
        if state == .changed {
            movePreviewChanged?(delta)
            transform = CGAffineTransform(rotationAngle: item.rotation ?? 0).concatenating(CGAffineTransform(translationX: delta.x, y: delta.y))
        }
        if state == .ended {
            transform = CGAffineTransform(rotationAngle: item.rotation ?? 0)
            if delta != .zero {
                Diagnostics.shared.record("sticky.move")
                item.x += delta.x / max(zoom, 0.01); item.y += delta.y / max(zoom, 0.01)
                changed?(item)
            } else { movePreviewCancelled?() }
        } else if state == .cancelled || state == .failed {
            transform = CGAffineTransform(rotationAngle: item.rotation ?? 0); movePreviewCancelled?()
        }
    }
    @objc func drag(_ pan: UIPanGestureRecognizer) {
        move(state: pan.state, delta: (pan as? StickyDragPan)?.translationFromInitialTouch(in: superview) ?? pan.translation(in: superview))
    }
    @objc private func dragCollapsed(_ hold: UILongPressGestureRecognizer) {
        let location = hold.location(in: superview)
        if hold.state == .began { initialCenter = location; UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
        move(state: hold.state, delta: CGPoint(x: location.x - initialCenter.x, y: location.y - initialCenter.y))
    }
}

// Lightweight "Undo" pill shown after a quick delete; replaces itself, disappears on its own.
private final class UndoToast: UIVisualEffectView {
    private let undo: () -> Void
    init(_ message: String, undo: @escaping () -> Void) {
        self.undo = undo
        super.init(effect: UIBlurEffect(style: .systemThinMaterial))
        tag = 7001; layer.cornerRadius = 20; clipsToBounds = true
        accessibilityIdentifier = "sticky.undoToast"
        let label = UILabel(); label.text = message; label.font = .preferredFont(forTextStyle: .subheadline); label.textColor = .label
        let button = UIButton(type: .system); button.setTitle("Undo", for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        button.addTarget(self, action: #selector(tapped), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [label, button]); stack.spacing = 14; stack.alignment = .center
        stack.layoutMargins = UIEdgeInsets(top: 0, left: 18, bottom: 0, right: 12); stack.isLayoutMarginsRelativeArrangement = true
        stack.frame = CGRect(origin: .zero, size: CGSize(width: 240, height: 40)); contentView.addSubview(stack)
        frame.size = CGSize(width: 240, height: 40)
        isAccessibilityElement = false; accessibilityElements = [button]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func tapped() { undo(); dismiss() }
    func dismiss() { UIView.animate(withDuration: 0.2, animations: { self.alpha = 0 }) { _ in self.removeFromSuperview() } }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont { UIFont.systemFont(ofSize: pointSize, weight: weight) }
}

extension PageScrollView {
    func showUndoToast(_ message: String, undo: @escaping () -> Void) {
        (viewWithTag(7001) as? UndoToast)?.removeFromSuperview()
        let toast = UndoToast(message, undo: undo)
        toast.center = CGPoint(x: bounds.midX, y: bounds.height - safeAreaInsets.bottom - 56)
        toast.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin]
        toast.alpha = 0; addSubview(toast)
        UIView.animate(withDuration: 0.18) { toast.alpha = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak toast] in if toast?.superview != nil { toast?.dismiss() } }
    }
}
