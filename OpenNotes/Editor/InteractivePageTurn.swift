import UIKit

final class InteractivePageTurn: NSObject, UIGestureRecognizerDelegate {
    weak var view: PageScrollView?
    var previous: UIImage?
    var next: UIImage?
    var canPrevious = false
    var canNext = false
    var prepare: ((Int) -> Void)?
    var addPage: ((Int) async -> Bool)?
    var disabled = false
    private var current: UIView?
    private var adjacent: UIView?
    private var blocker: UIView?
    private var direction = 1
    private var vertical = false
    private var installedPageID: UUID?
    private(set) var committing = false
    private var animationFinished = false
    private var navigationFinished = false
    private var installed = false
    private var readyPageID: UUID?
    private var sourcePageID: UUID?
    private var transitionID = UUID()
    private var navigationTask: Task<Void, Never>?
    func pageInstalled(_ id: UUID) {
        installedPageID = id
        guard committing, id != sourcePageID, !installed else { return }
        installed = true
        // The incoming preview stays until the paper has drawn the page (never longer than this).
        let request = transitionID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.transitionID == request, self.committing else { return }
            self.readyPageID = id; self.finishIfReady()
        }
        finishIfReady()
    }
    /// The paper of `id` shows its own content: the page turn overlay can go without a blank or stale frame.
    func paperReady(_ id: UUID) {
        readyPageID = id
        finishIfReady()
    }
    private func finishIfReady() {
        if committing && animationFinished && navigationFinished && installed && readyPageID == installedPageID { clear() }
    }
    let gesture = UIPanGestureRecognizer()
    init(view: PageScrollView) {
        self.view = view
        super.init()
        gesture.addTarget(self, action: #selector(drag(_:)))
        gesture.delegate = self
        gesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        gesture.minimumNumberOfTouches = 1
        gesture.maximumNumberOfTouches = 1
        view.canvas.addGestureRecognizer(gesture)
        view.zoomGesture.addTarget(self, action: #selector(zoomChanged(_:)))
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let view else { return false }
        return shouldBegin(velocity: gesture.velocity(in: view))
    }
    func shouldBegin(velocity: CGPoint) -> Bool {
        guard let view, !view.canvas.hasActivePencilStroke, !disabled, !committing, adjacent == nil, !view.isPinching, !view.canvas.isZooming else { return false }
        if view.canvas.zoomScale > view.canvas.minimumZoomScale + 0.02 {
            guard !view.verticalPaging, abs(velocity.x) > abs(velocity.y) else { return false }
            let scroll = view.canvas
            let left = -scroll.adjustedContentInset.left
            let right = max(left, scroll.contentSize.width - scroll.bounds.width + scroll.adjustedContentInset.right)
            return velocity.x > 0 ? scroll.contentOffset.x <= left + 1 : scroll.contentOffset.x >= right - 1
        }
        return view.verticalPaging ? abs(velocity.y) > abs(velocity.x) : abs(velocity.x) > abs(velocity.y)
    }
    static func shouldCommit(progress: CGFloat, speed: CGFloat, hasPage: Bool, canCreate: Bool) -> Bool {
        hasPage ? (speed > 650 || (progress >= 0.3 && speed > -350)) : (canCreate && progress >= 0.65 && speed > -350)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        otherGestureRecognizer === view?.zoomGesture
    }
    @objc private func zoomChanged(_ pinch: UIPinchGestureRecognizer) {
        guard pinch.state == .began, !committing, adjacent != nil else { return }
        clear()
        gesture.isEnabled = false; gesture.isEnabled = true
    }
    func detach() {
        clear()
        view?.zoomGesture.removeTarget(self, action: #selector(zoomChanged(_:)))
        gesture.view?.removeGestureRecognizer(gesture)
    }
    func clear() {
        transitionID = UUID(); navigationTask?.cancel(); navigationTask = nil
        prepare?(0)
        current?.layer.removeAllAnimations(); adjacent?.layer.removeAllAnimations()
        current?.removeFromSuperview(); adjacent?.removeFromSuperview(); blocker?.removeFromSuperview(); blocker = nil
        current = nil; adjacent = nil; committing = false; readyPageID = nil
        view?.selectionView?.isHidden = false
        animationFinished = false; navigationFinished = false; installed = false
    }
    private func previewFrame(in view: PageScrollView) -> CGRect? {
        guard let coordinator = view.canvas.delegate as? WritingCanvas.Coordinator else { return nil }
        let session = coordinator.session
        let pages = session.store.library.pages(in: session.noteID)
        guard let index = pages.firstIndex(where: { $0.id == sourcePageID }), pages.indices.contains(index + direction) else { return nil }
        let page = pages[index + direction], size = PageRenderer.size(page)
        let fit = max(0.1, min(4, (view.bounds.width - 32) / size.width, (view.bounds.height - 32) / size.height))
        let saved = UserDefaults.standard.array(forKey: "viewport-\(session.noteID)-\(page.id)") as? [Double]
        if let saved, let restored = PageScrollView.restoredZoom(saved, fit: fit) {
            let zoom = max(fit, min(4, restored))
            let width = size.width * zoom, height = size.height * zoom
            let horizontal = max(0, (view.bounds.width - width) / 2), vertical = max(0, (view.bounds.height - height) / 2)
            let x = min(max(CGFloat(saved[1]) * zoom - view.bounds.width / 2, -horizontal), max(-horizontal, width - view.bounds.width + horizontal))
            let y = min(max(CGFloat(saved[2]) * zoom - view.bounds.height / 2, -vertical), max(-vertical, height - view.bounds.height + vertical))
            return CGRect(x: -x, y: -y, width: width, height: height)
        }
        return CGRect(x: view.bounds.midX - size.width * fit / 2, y: view.bounds.midY - size.height * fit / 2,
                      width: size.width * fit, height: size.height * fit)
    }
    @objc func drag(_ pan: UIPanGestureRecognizer) {
        guard let view else { return }
        if pan.state == .failed { clear(); return }
        guard pan.state == .began || adjacent != nil else { return }
        let delta = pan.translation(in: view)
        if pan.state == .began { vertical = view.verticalPaging }
        let amount = vertical ? delta.y : delta.x
        let length = vertical ? view.bounds.height : view.bounds.width
        guard length > 0 else { return }
        if pan.state == .began {
            transitionID = UUID()
            let velocity = pan.velocity(in: view)
            let initial = amount == 0 ? (vertical ? velocity.y : velocity.x) : amount
            direction = initial < 0 ? 1 : -1
            sourcePageID = installedPageID ?? (view.canvas.delegate as? WritingCanvas.Coordinator)?.pageID
            Diagnostics.shared.record("paging.begin", ["direction": String(direction), "vertical": String(vertical)])
            prepare?(direction)
            view.selectionView?.dismissMenu(); view.selectionView?.isHidden = true
            current = view.snapshotView(afterScreenUpdates: false)
            current?.frame = view.bounds
            current?.isUserInteractionEnabled = false
            if let current { view.addSubview(current) }
            let preview = UIView(frame: view.bounds)
            preview.backgroundColor = .secondarySystemBackground
            preview.clipsToBounds = true
            preview.isUserInteractionEnabled = false
            let image = UIImageView(image: direction > 0 ? next : previous)
            image.contentMode = .scaleAspectFit
            image.frame = preview.bounds.insetBy(dx: 16, dy: 16)
            if let frame = previewFrame(in: view) { image.frame = frame; image.contentMode = .scaleToFill }
            preview.addSubview(image)
            if direction > 0 ? !canNext : !canPrevious {
                let label = UILabel(frame: preview.bounds.insetBy(dx: 30, dy: 30))
                label.text = "Pull farther to add a page"; label.numberOfLines = 0; label.textAlignment = .center
                label.font = .preferredFont(forTextStyle: .headline); preview.addSubview(label)
            } else if image.image == nil {
                let loading = UIActivityIndicatorView(style: .medium)
                loading.center = CGPoint(x: preview.bounds.midX, y: preview.bounds.midY)
                loading.accessibilityLabel = "Loading preview"
                preview.addSubview(loading); loading.startAnimating()
            }
            adjacent = preview; view.addSubview(preview)
        }
        let hasPage = direction > 0 ? canNext : canPrevious
        let progress = max(0, min(1, -amount * CGFloat(direction) / length))
        let travel = hasPage ? progress * length : min(progress * length * 0.65, length * 0.8)
        let position = -CGFloat(direction) * travel
        let move = CGAffineTransform(translationX: vertical ? 0 : position, y: vertical ? position : 0)
        let offset = CGFloat(direction) * length + position
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        current?.transform = reduceMotion ? .identity : move
        adjacent?.transform = reduceMotion ? .identity : CGAffineTransform(translationX: vertical ? 0 : offset, y: vertical ? offset : 0)
        current?.alpha = reduceMotion ? 1 - progress : 1
        adjacent?.alpha = reduceMotion ? progress : 1
        guard pan.state == .ended || pan.state == .cancelled else { return }
        let velocity = pan.velocity(in: view)
        let speed = -(vertical ? velocity.y : velocity.x) * CGFloat(direction)
        let create = !hasPage && progress >= 0.65
        let turn = pan.state == .ended && Self.shouldCommit(progress: progress, speed: speed, hasPage: hasPage, canCreate: !hasPage)
        Diagnostics.shared.record("paging.release", ["commit": String(turn), "create": String(create), "progress": String(Double(progress))])
        committing = turn
        let request = transitionID
        if turn {
            let blocking = UIView(frame: view.bounds)
            blocking.accessibilityViewIsModal = true
            blocking.isAccessibilityElement = true; blocking.accessibilityLabel = "Opening page"
            blocker = blocking; view.addSubview(blocking)
            let loading = UIActivityIndicatorView(style: .medium)
            loading.center = CGPoint(x: adjacent?.bounds.midX ?? 0, y: adjacent?.bounds.midY ?? 0)
            loading.accessibilityLabel = "Opening page"
            adjacent?.addSubview(loading); loading.startAnimating()
            navigationTask = Task { [weak self, weak view] in
                guard let self, let view else { return }
                let success = create ? await self.addPage?(self.direction) ?? false : await view.onNavigate?(self.direction) ?? false
                guard self.transitionID == request else { return }
                Diagnostics.shared.record("paging.navigation", ["success": String(success)])
                self.navigationFinished = true
                if success { self.finishIfReady() }
                else {
                    UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState, .curveEaseOut], animations: {
                        self.current?.transform = .identity
                        self.current?.alpha = 1
                        self.adjacent?.alpha = reduceMotion ? 0 : 1
                        let offset = CGFloat(self.direction) * length
                        self.adjacent?.transform = reduceMotion ? .identity : CGAffineTransform(translationX: self.vertical ? 0 : offset, y: self.vertical ? offset : 0)
                    }, completion: { _ in if self.transitionID == request { self.clear() } })
                }
            }
        }
        let destination = turn ? -CGFloat(direction) * length : 0
        let duration = reduceMotion ? 0.12 : min(0.28, max(0.12, Double(turn ? 1 - progress : progress) * 0.28))
        UIView.animate(withDuration: duration, delay: 0, options: [.beginFromCurrentState, .curveEaseOut], animations: {
            self.current?.transform = reduceMotion ? .identity : CGAffineTransform(translationX: self.vertical ? 0 : destination, y: self.vertical ? destination : 0)
            self.current?.alpha = reduceMotion && turn ? 0 : 1
            self.adjacent?.alpha = reduceMotion && !turn ? 0 : 1
            let incoming = CGFloat(self.direction) * length + destination
            self.adjacent?.transform = reduceMotion ? .identity : CGAffineTransform(translationX: self.vertical ? 0 : incoming, y: self.vertical ? incoming : 0)
        }, completion: { [self] _ in
            guard transitionID == request else { return }
            if turn {
                self.animationFinished = true; self.finishIfReady()
            } else { self.clear() }
        })
    }
}
