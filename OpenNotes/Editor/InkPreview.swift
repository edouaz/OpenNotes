import SwiftUI
import UIKit

struct InkPreview: View {
    @ObservedObject var session: EditorSession
    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale

    private var sample: InkPreviewSample? { InkPreviewSample(session: session) }

    var body: some View {
        let snapshot = sample
        VStack(alignment: .leading, spacing: 4) {
            if let snapshot {
                Text("Nominal width · \(Double(snapshot.inkWidth).formatted(.number.precision(.fractionLength(0...2)))) pt · \(Double(snapshot.inkWidth * displayScale).formatted(.number.precision(.fractionLength(0...1)))) px at 100%")
                    .font(.caption).monospacedDigit()
                Group {
                    if let image { Image(uiImage: image) }
                    else { ProgressView() }
                }
                .frame(width: InkPreviewSample.size.width, height: min(InkPreviewSample.size.height, max(72, snapshot.inkWidth + 16)))
                .clipped()
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.gray.opacity(0.35)))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Actual stroke preview on white paper at 100 percent")
                Text("Size at 100% · variable pressure · width guide on the left")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if session.selectedTool == .eraser {
                Text("Diameter · \(Int(session.toolSettings.eraserWidth)) pt · \(Int((session.toolSettings.eraserWidth * displayScale).rounded())) px at 100%").font(.caption).monospacedDigit()
                ZStack {
                    Color.white
                    Rectangle().fill(Color(uiColor: UIColor(presetHex: "#315BB1")!)).frame(width: 240, height: 16)
                    Circle().fill(.white).frame(width: session.toolSettings.eraserWidth, height: session.toolSettings.eraserWidth)
                        .overlay(Circle().strokeBorder(.gray, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                }.frame(width: 240, height: 96).clipShape(RoundedRectangle(cornerRadius: 8))
                Text("Eraser footprint at 100%").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("instrument.inkPreview")
        .task(id: snapshot) {
            guard let snapshot else { image = nil; return }
            let work = Task.detached(priority: .userInitiated) { snapshot.render() }
            let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled else { return }
            image = result
        }
    }
}

struct InkPreviewSample: Equatable {
    static let size = CGSize(width: 240, height: 144)
    let kind: DrawingToolKind
    let inkType: InkInk.InkType
    let color: UIColor
    let inkWidth: CGFloat
    let processingWidth: Double
    let settings: EditorToolSettings

    @MainActor
    init?(session: EditorSession) {
        guard session.selectedTool.isWritingTool, let tool = session.tool as? InkInkingTool else { return nil }
        kind = session.selectedTool
        inkType = tool.inkType
        color = tool.color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        inkWidth = tool.width
        processingWidth = session.documentInkWidth
        settings = session.toolSettings
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.inkType == rhs.inkType && lhs.color.isEqual(rhs.color) &&
        lhs.inkWidth == rhs.inkWidth && lhs.processingWidth == rhs.processingWidth && lhs.settings == rhs.settings
    }

    func drawing() -> InkDrawing {
        let margin = max(28, inkWidth / 2 + 20)
        let points = (0...80).map { index in
            let progress = CGFloat(index) / 80
            let location = CGPoint(x: margin + progress * (Self.size.width - margin * 2),
                                   y: Self.size.height / 2 + sin(progress * .pi * 2) * min(12, max(0, (Self.size.height - inkWidth) / 2 - 8)))
            return InkStrokePoint(location: location, timeOffset: Double(progress) * 0.8,
                                 size: CGSize(width: inkWidth, height: inkWidth), opacity: 1,
                                 force: 0.15 + 0.85 * sin(progress * .pi), azimuth: .pi / 4, altitude: .pi / 2)
        }
        let original = InkStroke(ink: InkInk(inkType, color: color),
                                path: InkStrokePath(controlPoints: points, creationDate: Date(timeIntervalSinceReferenceDate: 0)),
                                transform: .identity, randomSeed: 1)
        // Preview and live ink share processing, without activating hold recognition.
        let processed = StrokeProcessing.process(original, tool: kind, width: processingWidth, settings: settings, shapeHeld: false) ?? original
        return InkDrawing(strokes: [processed])
    }

    func render() -> UIImage? {
        guard !Task.isCancelled else { return nil }
        let ink = drawing().paperImage(from: CGRect(origin: .zero, size: Self.size), scale: 2)
        guard !Task.isCancelled else { return nil }
        var result: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            let format = UIGraphicsImageRendererFormat(); format.scale = 2; format.opaque = true
            result = UIGraphicsImageRenderer(size: Self.size, format: format).image { renderer in
                UIColor.white.setFill(); renderer.fill(CGRect(origin: .zero, size: Self.size))
                ink.draw(at: .zero)
                let top = (Self.size.height - inkWidth) / 2, bottom = top + inkWidth
                let context = renderer.cgContext
                context.setStrokeColor(UIColor.gray.cgColor); context.setLineWidth(0.5)
                context.move(to: CGPoint(x: 10, y: top)); context.addLine(to: CGPoint(x: 10, y: bottom))
                for y in [top, bottom] {
                    context.move(to: CGPoint(x: 6, y: y)); context.addLine(to: CGPoint(x: 14, y: y))
                }
                context.strokePath()
            }
        }
        return result
    }
}

// Swatches use the same translucent marker renderer as the document, on white paper.
struct PaperInkSwatch: View {
    let hex: String
    let marker: Bool
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            Color(uiColor: marker ? .white : UIColor(presetHex: hex) ?? .black)
            if marker, let image { Image(uiImage: image).resizable() }
        }
        .frame(width: 24, height: 24).clipShape(Circle())
        .task(id: "\(hex)-\(marker)") {
            guard marker else { image = nil; return }
            let color = UIColor(presetHex: hex) ?? .black
            let result = await Task.detached(priority: .userInitiated) { InkPreviewSample.markerSwatch(color: color) }.value
            guard !Task.isCancelled else { return }
            image = result
        }
    }
}

extension InkPreviewSample {
    static func markerSwatch(color: UIColor) -> UIImage {
        let bounds = CGRect(x: 0, y: 0, width: 24, height: 24)
        let points = [-24.0, 12, 48].enumerated().map { index, x in
            InkStrokePoint(location: CGPoint(x: x, y: 12), timeOffset: Double(index) * 0.1,
                          size: CGSize(width: 40, height: 40), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let stroke = InkStroke(ink: InkInk(.marker, color: color),
                              path: InkStrokePath(controlPoints: points, creationDate: Date(timeIntervalSinceReferenceDate: 0)),
                              transform: .identity, randomSeed: 1)
        let ink = InkDrawing(strokes: [stroke]).paperImage(from: bounds, scale: 2)
        let format = UIGraphicsImageRendererFormat(); format.scale = 2; format.opaque = true
        return UIGraphicsImageRenderer(size: bounds.size, format: format).image { renderer in
            UIColor.white.setFill(); renderer.fill(bounds)
            ink.draw(in: bounds)
        }
    }
}
