import UIKit

extension PageElement {
    var stickyPath: CGPath {
        let rect = CGRect(x: x, y: y, width: collapsed == true ? 44 : width, height: collapsed == true ? 44 : height)
        return CGPath(roundedRect: rect, cornerWidth: stickyRadius, cornerHeight: stickyRadius, transform: nil)
    }
    var objectTransform: CGAffineTransform {
        let rect = CGRect(x: x, y: y, width: collapsed == true ? 44 : width, height: collapsed == true ? 44 : height)
        let angle = rotation ?? 0, c = cos(angle), s = sin(angle)
        return CGAffineTransform(a: c, b: s, c: -s, d: c,
                                 tx: rect.midX - c * rect.midX + s * rect.midY,
                                 ty: rect.midY - s * rect.midX - c * rect.midY)
    }
    var visiblePath: CGPath {
        let rect = CGRect(x: x, y: y, width: collapsed == true ? 44 : width, height: collapsed == true ? 44 : height)
        let shape: CGPath
        switch kind {
        case .stickyNote: shape = stickyPath
        case .ellipse: shape = CGPath(ellipseIn: rect, transform: nil)
        case .line, .arrow:
            let line = CGMutablePath()
            line.move(to: rect.origin); line.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            if kind == .arrow {
                let angle = atan2(rect.height, rect.width)
                for offset in [-0.5, 0.5] {
                    line.move(to: CGPoint(x: rect.maxX, y: rect.maxY))
                    line.addLine(to: CGPoint(x: rect.maxX - 20 * cos(angle + offset), y: rect.maxY - 20 * sin(angle + offset)))
                }
            }
            shape = line.copy(strokingWithWidth: strokeWidth ?? 2, lineCap: .round, lineJoin: .round, miterLimit: 1)
        default: shape = CGPath(rect: rect, transform: nil)
        }
        var transform = objectTransform
        return shape.copy(using: &transform) ?? shape
    }
    var visibleBounds: CGRect { visiblePath.boundingBoxOfPath }
}
