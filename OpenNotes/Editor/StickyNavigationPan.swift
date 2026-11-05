import UIKit
import UIKit.UIGestureRecognizerSubclass

// Note overlays are siblings of the canvas, so their two-finger navigation starts on the parent.
final class StickyNavigationPan: UIPanGestureRecognizer {
    var trackingChanged: ((Bool) -> Void)?
    var additionalTouch: (() -> Void)?
    private(set) weak var note: StickyNoteControl?
    private var trackingNote = false
    private var touchCount = 0
    private var reportedAdditionalTouch = false

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        configure()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configure() {
        minimumNumberOfTouches = 2
        maximumNumberOfTouches = 2
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        cancelsTouchesInView = false
    }

    @discardableResult
    func observeTouchBegin(firstView: UIView?, count: Int) -> Bool {
        if !trackingNote {
            var current = firstView
            while let view = current, !(view is StickyNoteControl) { current = view.superview }
            guard let note = current as? StickyNoteControl else { return false }
            self.note = note
            trackingNote = true
            trackingChanged?(true)
        }
        touchCount += count
        if touchCount >= 2 && !reportedAdditionalTouch {
            reportedAdditionalTouch = true
            additionalTouch?()
        }
        return true
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard observeTouchBegin(firstView: touches.min(by: { $0.timestamp < $1.timestamp })?.view, count: touches.count) else {
            state = .failed
            return
        }
        super.touchesBegan(touches, with: event)
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func reset() {
        let wasTracking = trackingNote
        trackingNote = false
        note = nil
        touchCount = 0
        reportedAdditionalTouch = false
        super.reset()
        if wasTracking { trackingChanged?(false) }
    }
}
