import XCTest
import UIKit
@testable import OpenNotes

@MainActor
final class StickyAppearanceTests: XCTestCase {
    func testAttachedElementClipsToRoundedAndResizedParent() throws {
        var note = PageElement(kind: .stickyNote, x: 20, y: 20, width: 40, height: 40, text: "")
        note.stickyCornerRadius = 20
        var child = PageElement(kind: .rectangle, x: 20, y: 20, width: 80, height: 80)
        child.parentID = note.id; child.fillColorHex = "#0000FF"
        var page = NotePage(noteID: UUID(), index: 0, format: .a4Portrait, template: .blank, drawingResourceID: "ink.drawing")
        page.elements = [note, child]
        let image = try XCTUnwrap(PageRenderer.image(page, data: nil).cgImage)
        func pixel(_ x: Int, _ y: Int) throws -> [UInt8] {
            let crop = try XCTUnwrap(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
            var bytes = [UInt8](repeating: 0, count: 4)
            bytes.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            return bytes
        }
        let corner = try pixel(21, 21), center = try pixel(40, 40), outside = try pixel(70, 40)
        XCTAssertGreaterThan(corner[0], 245); XCTAssertGreaterThan(corner[1], 245)
        XCTAssertLessThan(center[0], 10); XCTAssertLessThan(center[1], 10)
        XCTAssertGreaterThan(outside[0], 245); XCTAssertGreaterThan(outside[1], 245)
    }

    func testNestedInkClipsToParentAndHiddenNotesDoNotOcclude() throws {
        var note = PageElement(kind: .stickyNote, x: 20, y: 20, width: 40, height: 40)
        var child = PageElement(kind: .text, x: 25, y: 25, width: 20, height: 20)
        child.parentID = note.id
        let points = [CGPoint(x: 0, y: 40), CGPoint(x: 160, y: 40)].enumerated().map {
            InkStrokePoint(location: $0.element, timeOffset: Double($0.offset), size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        var stroke = InkStroke(ink: InkInk(.pen, color: .black), path: InkStrokePath(controlPoints: points, creationDate: Date()))
        stroke.parentID = child.id
        let clipped = try XCTUnwrap(StickyInkOcclusion([note, child]).visible(stroke))
        XCTAssertTrue(clipped.paintedPath.contains(CGPoint(x: 40, y: 40)))
        XCTAssertFalse(clipped.paintedPath.contains(CGPoint(x: 80, y: 40)))
        note.collapsed = true
        var hidden = PageElement(kind: .stickyNote, x: 100, y: 20, width: 40, height: 40)
        hidden.parentID = note.id
        stroke.parentID = nil
        let visible = try XCTUnwrap(StickyInkOcclusion([note, hidden]).visible(stroke))
        XCTAssertTrue(visible.paintedPath.contains(CGPoint(x: 120, y: 40)))
        XCTAssertFalse(visible.paintedPath.contains(CGPoint(x: 40, y: 40)))
    }

    func testNestedNoteCannotOccludeInkOutsideItsParent() throws {
        let parent = PageElement(kind: .stickyNote, x: 20, y: 20, width: 40, height: 40)
        var child = PageElement(kind: .stickyNote, x: 40, y: 20, width: 80, height: 40)
        child.parentID = parent.id
        let points = [CGPoint(x: 0, y: 40), CGPoint(x: 140, y: 40)].enumerated().map {
            InkStrokePoint(location: $0.element, timeOffset: Double($0.offset), size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let stroke = InkStroke(ink: InkInk(.pen, color: .black), path: InkStrokePath(controlPoints: points, creationDate: Date()))
        let visible = try XCTUnwrap(StickyInkOcclusion([parent, child]).visible(stroke))
        XCTAssertFalse(visible.paintedPath.contains(CGPoint(x: 50, y: 40)))
        XCTAssertTrue(visible.paintedPath.contains(CGPoint(x: 90, y: 40)))
    }

    func testLegacyDefaultsAndAppearanceRoundTrip() throws {
        var note = PageElement(kind: .stickyNote)
        let legacy = try JSONDecoder().decode(PageElement.self, from: JSONEncoder().encode(note))
        XCTAssertEqual(legacy.stickyRadius, 0); XCTAssertEqual(legacy.stickyBackgroundOpacity, 1)
        XCTAssertEqual(legacy.stickyShadowOpacity, 0); XCTAssertEqual(legacy.stickyBorderWidth, 0)
        note.stickyCornerRadius = 12; note.stickyOpacity = 0.5; note.stickyShadow = 0.2
        note.strokeWidth = 3; note.strokeColorHex = "#123456"
        XCTAssertEqual(try JSONDecoder().decode(PageElement.self, from: JSONEncoder().encode(note)), note)
        note.stickyCornerRadius = .infinity; note.stickyOpacity = -1; note.stickyShadow = 10; note.strokeWidth = .nan
        XCTAssertEqual(note.stickyRadius, 0); XCTAssertEqual(note.stickyBackgroundOpacity, 0)
        XCTAssertEqual(note.stickyShadowOpacity, 0.3); XCTAssertEqual(note.stickyBorderWidth, 0)
    }

    func testRoundedSilhouetteAndRenderedBackground() throws {
        var note = PageElement(kind: .stickyNote, x: 20, y: 20, width: 80, height: 80, text: "")
        note.stickyCornerRadius = 20; note.stickyOpacity = 0.5; note.fillColorHex = "#FF0000"
        XCTAssertFalse(note.visiblePath.contains(CGPoint(x: 21, y: 21)))
        XCTAssertTrue(note.visiblePath.contains(CGPoint(x: 60, y: 60)))
        var page = NotePage(noteID: UUID(), index: 0, format: .a4Portrait, template: .blank, drawingResourceID: "ink.drawing")
        page.elements = [note]
        let image = try XCTUnwrap(PageRenderer.image(page, data: nil).cgImage)
        func pixel(_ x: Int, _ y: Int) throws -> [UInt8] {
            let crop = try XCTUnwrap(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
            var bytes = [UInt8](repeating: 0, count: 4)
            bytes.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            return bytes
        }
        let corner = try pixel(20, 20), center = try pixel(60, 60)
        XCTAssertGreaterThan(corner[1], 245)
        XCTAssertGreaterThan(center[0], 245); XCTAssertEqual(Int(center[1]), 128, accuracy: 3)
        note.collapsed = true
        XCTAssertFalse(note.visiblePath.contains(CGPoint(x: 21, y: 21)))
        XCTAssertTrue(note.visiblePath.contains(CGPoint(x: 42, y: 42)))
    }
}
