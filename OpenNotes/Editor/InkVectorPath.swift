import CoreGraphics
import Foundation

// Store the final vector silhouette; screen, selection and PDF use the same geometry.
struct InkVectorPath: Codable, Equatable {
    struct Element: Codable, Equatable {
        var kind: Int
        var points: [CGPoint]
    }
    // Rebuilding (and re-validating) the CGPath on every access was the eraser's main repeated cost.
    // Mutation installs a fresh box, so copies of the struct never see each other's stale path.
    private final class Cache {
        private let lock = NSLock()
        private var path: CGPath?
        func path(build: () -> CGPath) -> CGPath {
            lock.lock(); defer { lock.unlock() }
            if let path { return path }
            let built = build(); path = built; return built
        }
    }
    private var cache = Cache()
    var elements: [Element] { didSet { cache = Cache() } }
    private enum CodingKeys: String, CodingKey { case elements }
    static func == (a: Self, b: Self) -> Bool { a.elements == b.elements }
    init(_ path: CGPath) {
        var result: [Element] = []
        path.applyWithBlock { pointer in
            let item = pointer.pointee
            let count: Int
            switch item.type {
            case .moveToPoint, .addLineToPoint: count = 1
            case .addQuadCurveToPoint: count = 2
            case .addCurveToPoint: count = 3
            case .closeSubpath: count = 0
            @unknown default: count = 0
            }
            result.append(Element(kind: Int(item.type.rawValue), points: (0..<count).map { item.points[$0] }))
        }
        elements = result
    }
    var valid: Bool {
        let counts = [1, 1, 2, 3, 0]
        return elements.count <= 1_000_000 && elements.allSatisfy {
            counts.indices.contains($0.kind) && $0.points.count == counts[$0.kind] &&
            $0.points.allSatisfy { $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 1_000_000 && abs($0.y) <= 1_000_000 }
        }
    }
    var cgPath: CGPath { cache.path { build() } }
    private func build() -> CGPath {
        let path = CGMutablePath()
        guard valid else { return path }
        for item in elements {
            switch item.kind {
            case 0: path.move(to: item.points[0])
            case 1: path.addLine(to: item.points[0])
            case 2: path.addQuadCurve(to: item.points[1], control: item.points[0])
            case 3: path.addCurve(to: item.points[2], control1: item.points[0], control2: item.points[1])
            case 4: path.closeSubpath()
            default: break
            }
        }
        return path
    }
}
