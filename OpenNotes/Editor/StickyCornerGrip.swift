import UIKit

/// Stage Manager–style corner grip: a small rounded "L" that hugs the corner it resizes.
/// Drawn once for the top-left corner, then mirrored for the other three.
final class StickyCornerGrip: UIView {
    private let shape = CAShapeLayer()
    init(corner: Int) {
        super.init(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        isUserInteractionEnabled = false
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 9, y: 24)); path.addLine(to: CGPoint(x: 9, y: 17))
        path.addArc(withCenter: CGPoint(x: 17, y: 17), radius: 8, startAngle: .pi, endAngle: 1.5 * .pi, clockwise: true)
        path.addLine(to: CGPoint(x: 24, y: 9))
        shape.path = path.cgPath; shape.fillColor = nil
        // Dark with a white halo: the grips now sit outside the note, on the (always white) paper.
        shape.strokeColor = UIColor(white: 0.28, alpha: 0.9).cgColor; shape.lineWidth = 3; shape.lineCap = .round; shape.lineJoin = .round
        shape.shadowColor = UIColor.white.cgColor; shape.shadowOpacity = 0.9; shape.shadowRadius = 1.5; shape.shadowOffset = .zero
        layer.addSublayer(shape)
        transform = CGAffineTransform(scaleX: corner % 2 == 0 ? 1 : -1, y: corner < 2 ? 1 : -1)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
