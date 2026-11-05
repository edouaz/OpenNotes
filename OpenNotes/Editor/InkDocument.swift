import UIKit

// Source samples and rendered geometry are separate so editing never destroys acquisition data.
enum InkPattern: String, Codable, CaseIterable { case solid, dashed, dotted }

struct InkStyle: Codable, Equatable {
    var kind: EditorToolSettings.PenStyle = .ballpoint
    var width: Double = 3
    var pattern: InkPattern = .solid
    var sharpness: Double = 0
    var stabilization: Double = 0
    var pressureResponse: Double = 0.5
    var inkAlgorithmVersion = 1
}

extension InkStyle {
    private enum CodingKeys: String, CodingKey { case kind, width, pattern, sharpness, stabilization, pressureResponse, inkAlgorithmVersion }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decodeIfPresent(EditorToolSettings.PenStyle.self, forKey: .kind) ?? .ballpoint
        width = try values.decode(Double.self, forKey: .width)
        pattern = try values.decodeIfPresent(InkPattern.self, forKey: .pattern) ?? .solid
        sharpness = try values.decodeIfPresent(Double.self, forKey: .sharpness) ?? 0
        stabilization = try values.decodeIfPresent(Double.self, forKey: .stabilization) ?? 0
        pressureResponse = try values.decodeIfPresent(Double.self, forKey: .pressureResponse) ?? 0.5
        inkAlgorithmVersion = try values.decodeIfPresent(Int.self, forKey: .inkAlgorithmVersion) ?? 1
    }
}

struct InkStrokePoint: Codable, Equatable {
    var location: CGPoint
    var timeOffset: TimeInterval
    var size: CGSize
    var opacity: CGFloat
    var force: CGFloat
    var azimuth: CGFloat
    var altitude: CGFloat

    static func interpolate(_ a: Self, _ b: Self, fraction: CGFloat) -> Self {
        let f = min(1, max(0, fraction))
        func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * f }
        return Self(location: CGPoint(x: mix(a.location.x, b.location.x), y: mix(a.location.y, b.location.y)),
                    timeOffset: a.timeOffset + (b.timeOffset - a.timeOffset) * Double(f),
                    size: CGSize(width: mix(a.size.width, b.size.width), height: mix(a.size.height, b.size.height)),
                    opacity: mix(a.opacity, b.opacity), force: mix(a.force, b.force),
                    azimuth: mix(a.azimuth, b.azimuth), altitude: mix(a.altitude, b.altitude))
    }
    fileprivate var valid: Bool {
        [location.x, location.y, size.width, size.height, opacity, force, azimuth, altitude].allSatisfy(\.isFinite) &&
        timeOffset.isFinite && timeOffset >= 0 && abs(location.x) <= 1_000_000 && abs(location.y) <= 1_000_000 &&
        (0...4096).contains(size.width) && (0...4096).contains(size.height) &&
        (0...1).contains(opacity) && (0...1).contains(force)
    }
}

struct InkStrokePath: Codable, RandomAccessCollection {
    var controlPoints: [InkStrokePoint]
    var creationDate: Date
    init(controlPoints: [InkStrokePoint], creationDate: Date) { self.controlPoints = controlPoints; self.creationDate = creationDate }
    var startIndex: Int { controlPoints.startIndex }
    var endIndex: Int { controlPoints.endIndex }
    subscript(index: Int) -> InkStrokePoint { controlPoints[index] }
    enum Interpolation { case distance(CGFloat) }
    func interpolatedPoints(by interpolation: Interpolation) -> [InkStrokePoint] {
        guard case let .distance(spacing) = interpolation, spacing.isFinite, spacing > 0,
              let first else { return Array(self) }
        var result = [first]
        for (a, b) in zip(self, dropFirst()) {
            let length = hypot(b.location.x - a.location.x, b.location.y - a.location.y)
            let count = Int(Swift.min(100_000, Swift.max(1, ceil(length / spacing))))
            for step in 1...count { result.append(.interpolate(a, b, fraction: CGFloat(step) / CGFloat(count))) }
        }
        return result
    }
}

struct InkInk: Codable {
    enum InkType: String, Codable {
        case pen, fountainPen, marker, pencil, monoline
        var validWidthRange: ClosedRange<CGFloat> { 0.1...128 }
    }
    var inkType: InkType
    var color: UIColor
    init(_ inkType: InkType, color: UIColor) {
        self.inkType = inkType
        self.color = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
    }
    private enum CodingKeys: String, CodingKey { case inkType, rgbaSRGB }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        inkType = try box.decode(InkType.self, forKey: .inkType)
        let rgba = try box.decode([Double].self, forKey: .rgbaSRGB)
        guard rgba.count == 4, rgba.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw InkDocumentError.invalidDocument }
        color = UIColor(red: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3])
    }
    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(inkType, forKey: .inkType)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { throw InkDocumentError.invalidDocument }
        try box.encode([r, g, b, a].map(Double.init), forKey: .rgbaSRGB)
    }
}

enum InkDocumentError: LocalizedError {
    case invalidDocument, unsupportedVersion
    var errorDescription: String? {
        switch self {
        case .invalidDocument: return "This page contains unsupported or invalid ink. Old PencilKit pages are not supported by this build."
        case .unsupportedVersion: return "This page uses an unsupported ink version."
        }
    }
}

struct InkStroke: Codable, Identifiable {
    var id: UUID
    var ink: InkInk
    var path: InkStrokePath { didSet { cache = GeometryCache() } }
    var rawSamples: [InkStrokePoint]
    var style: InkStyle? { didSet { cache = GeometryCache() } }
    var transform: CGAffineTransform
    var randomSeed: UInt32
    var vectorOutline: InkVectorPath? { didSet { cache = GeometryCache() } }
    // Painted geometry and bounds depend only on path, style and vectorOutline; reset when any changes.
    // The painted path is also what the retained CALayer holds, so caching adds no second copy.
    private final class GeometryCache {
        private let lock = NSLock()
        private var painted: CGPath?, bounds: CGRect?
        func paintedPath(_ build: () -> CGPath) -> CGPath {
            lock.lock(); defer { lock.unlock() }
            if let painted { return painted }
            let built = build(); painted = built; return built
        }
        func renderBounds(_ build: () -> CGRect) -> CGRect {
            lock.lock(); defer { lock.unlock() }
            if let bounds { return bounds }
            let built = build(); bounds = built; return built
        }
    }
    private var cache = GeometryCache()
    var parentID: UUID?
    var isLocked: Bool?
    var zIndex: Double?
    init(ink: InkInk, path: InkStrokePath, transform: CGAffineTransform = .identity,
         randomSeed: UInt32 = 0, style: InkStyle? = nil,
         rawSamples: [InkStrokePoint]? = nil, id: UUID = UUID()) {
        self.id = id; self.ink = ink; self.path = path; self.transform = transform
        self.randomSeed = randomSeed; self.style = style; self.rawSamples = rawSamples ?? Array(path)
    }
    private enum CodingKeys: String, CodingKey { case id, ink, path, rawSamples, style, transform, randomSeed, vectorOutline, parentID, isLocked, zIndex }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decode(UUID.self, forKey: .id); ink = try box.decode(InkInk.self, forKey: .ink)
        path = try box.decode(InkStrokePath.self, forKey: .path)
        rawSamples = try box.decode([InkStrokePoint].self, forKey: .rawSamples)
        style = try box.decodeIfPresent(InkStyle.self, forKey: .style)
        vectorOutline = try box.decodeIfPresent(InkVectorPath.self, forKey: .vectorOutline)
        parentID = try box.decodeIfPresent(UUID.self, forKey: .parentID)
        isLocked = try box.decodeIfPresent(Bool.self, forKey: .isLocked)
        zIndex = try box.decodeIfPresent(Double.self, forKey: .zIndex)
        randomSeed = try box.decode(UInt32.self, forKey: .randomSeed)
        let t = try box.decode([Double].self, forKey: .transform)
        guard t.count == 6, t.allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }) else { throw InkDocumentError.invalidDocument }
        transform = CGAffineTransform(a: t[0], b: t[1], c: t[2], d: t[3], tx: t[4], ty: t[5])
        guard valid else { throw InkDocumentError.invalidDocument }
    }
    func encode(to encoder: Encoder) throws {
        guard valid else { throw InkDocumentError.invalidDocument }
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encodeIfPresent(vectorOutline, forKey: .vectorOutline)
        try box.encodeIfPresent(parentID, forKey: .parentID)
        try box.encodeIfPresent(isLocked, forKey: .isLocked)
        try box.encodeIfPresent(zIndex, forKey: .zIndex)
        try box.encode(id, forKey: .id); try box.encode(ink, forKey: .ink)
        try box.encode(path, forKey: .path); try box.encode(rawSamples, forKey: .rawSamples)
        try box.encodeIfPresent(style, forKey: .style); try box.encode(randomSeed, forKey: .randomSeed)
        try box.encode([transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty].map(Double.init), forKey: .transform)
    }
    fileprivate var valid: Bool {
        guard zIndex.map({ $0.isFinite && abs($0) <= 1_000_000 }) != false, vectorOutline?.valid != false, path.count <= 1_000_000, rawSamples.count <= 1_000_000,
              path.creationDate.timeIntervalSinceReferenceDate.isFinite,
              path.allSatisfy(\.valid), rawSamples.allSatisfy(\.valid),
              zip(rawSamples, rawSamples.dropFirst()).allSatisfy({ $0.timeOffset <= $1.timeOffset }),
              [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty].allSatisfy(\.isFinite),
              abs(transform.a * transform.d - transform.b * transform.c) > 1e-12 else { return false }
        if let style {
            return style.inkAlgorithmVersion == 1 && style.width.isFinite && (0.1...4096).contains(style.width) &&
                [style.sharpness, style.stabilization, style.pressureResponse].allSatisfy { $0.isFinite && (0...1).contains($0) }
        }
        return true
    }
    var renderBounds: CGRect {
        let local = cache.renderBounds {
            if let vectorOutline { return vectorOutline.cgPath.boundingBoxOfPath }
            var result = CGRect.null
            for point in path {
                let radius = max(point.size.width, point.size.height) / 2
                result = result.union(CGRect(x: point.location.x - radius, y: point.location.y - radius,
                                            width: max(0.01, radius * 2), height: max(0.01, radius * 2)))
            }
            return result
        }
        return local.isNull ? .null : local.applying(transform)
    }

    // Patterns use accumulated distance, so sampling frequency cannot change their phase.
    func paintedPaths() -> [[InkStrokePoint]] {
        guard let first = path.first else { return [] }
        let samples = Array(path)
        let pattern = style?.pattern ?? .solid
        guard samples.count > 1 else { return [[first]] }
        var lengths = [CGFloat.zero]
        for (a, b) in zip(samples, samples.dropFirst()) {
            lengths.append(lengths.last! + hypot(b.location.x - a.location.x, b.location.y - a.location.y))
        }
        let total = lengths.last!
        guard total > 0.001 else { return [[first]] }
        let width = CGFloat(style?.width ?? Double(first.size.width))
        let taper = CGFloat(style?.sharpness ?? 0)
        func tapered(_ source: InkStrokePoint, distance: CGFloat) -> InkStrokePoint {
            var source = source
            let taperLength = min(total / 2, max(0.1, width * 1.5))
            let edge = min(1, max(0, min(distance, total - distance) / taperLength))
            let smooth = edge * edge * (3 - 2 * edge)
            let factor = max(0.08, 1 - taper + taper * smooth)
            source.size.width *= factor; source.size.height *= factor
            return source
        }
        var cursor = 0
        func sample(at distance: CGFloat) -> InkStrokePoint {
            while cursor + 1 < lengths.count - 1 && lengths[cursor + 1] < distance { cursor += 1 }
            let span = lengths[cursor + 1] - lengths[cursor]
            return tapered(.interpolate(samples[cursor], samples[cursor + 1], fraction: span > 0 ? (distance - lengths[cursor]) / span : 0), distance: distance)
        }
        if pattern == .solid {
            guard taper > 0 else { return [samples] }
            // Held lines can have only two points; sample the caps so their shaft keeps its width.
            let capLength = min(total / 2, max(0.1, width * 1.5))
            let caps = (0...4).flatMap { step -> [CGFloat] in
                let distance = capLength * CGFloat(step) / 4
                return [distance, total - distance]
            }
            return [Set(lengths + caps).sorted().map { sample(at: $0) }]
        }
        let unit = max(0.1, width)
        if pattern == .dotted {
            var dots: [[InkStrokePoint]] = []
            var distance: CGFloat = 0
            while distance <= total && dots.count < 1_000_000 {
                dots.append([sample(at: distance)]); distance += unit * 2.2
            }
            return dots
        }
        var pieces: [[InkStrokePoint]] = []
        var start: CGFloat = 0
        while start < total && pieces.count < 1_000_000 {
            let end = min(total, start + unit * 3)
            var piece = [sample(at: start)]
            var index = cursor + 1
            while index < samples.count && lengths[index] < end {
                piece.append(tapered(samples[index], distance: lengths[index])); index += 1
            }
            piece.append(sample(at: end)); pieces.append(piece)
            start += unit * 5
        }
        return pieces
    }
    var paintedPath: CGPath {
        cache.paintedPath {
            if let vectorOutline { return vectorOutline.cgPath }
            let outline = CGMutablePath()
            for points in paintedPaths() { Self.addOutline(of: points, from: 0, to: outline) }
            return outline
        }
    }
    // Round dot per sample plus a quad per segment. Winding numbers add, so appending only the new
    // tail (live preview) yields the same fill as rebuilding the whole outline.
    static func addOutline(of points: [InkStrokePoint], from start: Int, to outline: CGMutablePath) {
        guard start < points.count else { return }
        for point in points[start...] {
            let radius = max(0.025, max(point.size.width, point.size.height) / 2)
            outline.addEllipse(in: CGRect(x: point.location.x - radius, y: point.location.y - radius,
                                         width: radius * 2, height: radius * 2))
        }
        for index in max(1, start)..<max(1, points.count) {
            let a = points[index - 1], b = points[index]
            let dx = b.location.x - a.location.x, dy = b.location.y - a.location.y
            let distance = hypot(dx, dy)
            guard distance > 0.0001 else { continue }
            let na = CGPoint(x: -dy / distance * a.size.width / 2, y: dx / distance * a.size.width / 2)
            let nb = CGPoint(x: -dy / distance * b.size.width / 2, y: dx / distance * b.size.width / 2)
            outline.move(to: CGPoint(x: a.location.x + na.x, y: a.location.y + na.y))
            outline.addLine(to: CGPoint(x: a.location.x - na.x, y: a.location.y - na.y))
            outline.addLine(to: CGPoint(x: b.location.x - nb.x, y: b.location.y - nb.y))
            outline.addLine(to: CGPoint(x: b.location.x + nb.x, y: b.location.y + nb.y))
            outline.closeSubpath()
        }
    }
    func draw(in context: CGContext) {
        guard !path.isEmpty else { return }
        context.saveGState(); defer { context.restoreGState() }
        context.concatenate(transform)
        let color = ink.color.withAlphaComponent(ink.color.cgColor.alpha * (ink.inkType == .marker ? 0.3 : 1))
        context.setFillColor(color.cgColor)
        context.addPath(paintedPath); context.fillPath()
    }
}

struct InkDrawing: Codable {
    private(set) var inkSchemaVersion = 2
    var strokes: [InkStroke]
    init(strokes: [InkStroke] = []) { self.strokes = strokes }
    init(data: Data) throws {
        guard data.count <= 128 * 1024 * 1024 else { throw InkDocumentError.invalidDocument }
        self = try JSONDecoder().decode(Self.self, from: data)
        guard (1...2).contains(inkSchemaVersion) else { throw InkDocumentError.unsupportedVersion }
        guard strokes.count <= 100_000, Set(strokes.map(\.id)).count == strokes.count,
              strokes.reduce(0, { $0 + $1.path.count + $1.rawSamples.count }) <= 4_000_000 else { throw InkDocumentError.invalidDocument }
    }
    func encodedData() throws -> Data {
        guard (1...2).contains(inkSchemaVersion), strokes.count <= 100_000,
              Set(strokes.map(\.id)).count == strokes.count,
              strokes.reduce(0, { $0 + $1.path.count + $1.rawSamples.count }) <= 4_000_000 else { throw InkDocumentError.invalidDocument }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var latest = self; latest.inkSchemaVersion = 2
        let result = try encoder.encode(latest)
        guard result.count <= 128 * 1024 * 1024 else { throw InkDocumentError.invalidDocument }
        return result
    }
    // Nonthrowing compatibility for snapshot comparisons; all writes use encodedData().
    func dataRepresentation() -> Data { (try? encodedData()) ?? Data() }
    func draw(in context: CGContext, rect: CGRect? = nil) {
        for stroke in strokes where rect == nil || stroke.renderBounds.intersects(rect!) { stroke.draw(in: context) }
    }
    var bounds: CGRect { strokes.reduce(CGRect.null) { $0.union($1.renderBounds) } }
    func transformed(using transform: CGAffineTransform) -> Self {
        var copy = self
        copy.strokes = strokes.map { original in
            var stroke = original
            stroke.transform = original.transform.concatenating(transform)
            return stroke
        }
        return copy
    }
    func image(from rect: CGRect, scale: CGFloat) -> UIImage {
        guard !rect.isNull, !rect.isEmpty, rect.width.isFinite, rect.height.isFinite,
              scale.isFinite, scale > 0, rect.width * scale <= 16_384, rect.height * scale <= 16_384 else { return UIImage() }
        let format = UIGraphicsImageRendererFormat(); format.scale = scale; format.opaque = false
        return UIGraphicsImageRenderer(size: rect.size, format: format).image { output in
            output.cgContext.translateBy(x: -rect.minX, y: -rect.minY)
            for stroke in strokes where stroke.renderBounds.intersects(rect) { stroke.draw(in: output.cgContext) }
        }
    }
}
