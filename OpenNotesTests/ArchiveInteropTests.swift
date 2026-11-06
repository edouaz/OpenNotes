import XCTest
@testable import OpenNotes

/// Golden-file interoperability with the Node MCP server: `fixtures/swift-archive.json` is what this app writes (checked byte for byte here,
/// read and edited by `server/test/interop.test.mjs`), `fixtures/node-archive.json` is what the MCP writes (decoded here).
/// If the app's format changes, set TEST_RUNNER_REGENERATE_FIXTURES=1, rerun this test, then run `npm test` in server/.
final class ArchiveInteropTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures")
    private static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
    private static let pdf = Data(base64Encoded: "JVBERi0xLjcKJYGBgYEKCjUgMCBvYmoKPDwKL0ZpbHRlciAvRmxhdGVEZWNvZGUKL1R5cGUgL09ialN0bQovTiA0Ci9GaXJzdCAyMAovTGVuZ3RoIDI2MQo+PgpzdHJlYW0KeJzVUk1LxDAQvedXzNE9ZZqmaVdKYe3HRYRl8aTsIWzDUpCN9AP03/vSrIoH8SzhkUzem2SSNwkxKdKaUsoL0pSlispSyMf3V0dyb89uEvJ+6Cd6Bst0oKOQtV8uMyWiqsS3trazffFnEZMoCeJPxX70/XJyI5Vd23XMOTMbDRhm1WCugS2gEINTBdZArq/AXp4ypztwXYTJY07gV212zW8xQ2uCpolaXcT4695wVxvPUH/Vs62EfPB9Y2dHN82tYmWShIPScPa0wXeMzs7+/z5urX/wl19f+MPnYG8weXShB1aX5cFNfhlPsB26KvyX6wd759/QNYyBigkVoHdAfgAwEY3BCmVuZHN0cmVhbQplbmRvYmoKCjYgMCBvYmoKPDwKL1NpemUgNwovUm9vdCAyIDAgUgovSW5mbyAzIDAgUgovRmlsdGVyIC9GbGF0ZURlY29kZQovVHlwZSAvWFJlZgovTGVuZ3RoIDM0Ci9XIFsgMSAyIDIgXQovSW5kZXggWyAwIDcgXQo+PgpzdHJlYW0KeJwVxDEOACAIBLAext3/+ngIHYructmy1XbikXwGQ4wCrwplbmRzdHJlYW0KZW5kb2JqCgpzdGFydHhyZWYKMzc5CiUlRU9G")!
    private func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "E0000000-0000-4000-8000-%012d", n))! }

    private func stroke(_ type: InkInk.InkType, number: Int, parent: UUID? = nil) -> InkStroke {
        let points = [CGPoint(x: 20, y: 20), CGPoint(x: 80, y: 60), CGPoint(x: 140, y: 30)].enumerated().map { index, point in
            InkStrokePoint(location: point, timeOffset: Double(index) / 120, size: CGSize(width: 3, height: 3), opacity: 1, force: 0.5, azimuth: 0, altitude: 1)
        }
        var result = InkStroke(ink: InkInk(type, color: UIColor(red: 0.1, green: 0.2, blue: 0.8, alpha: 1)),
                               path: InkStrokePath(controlPoints: points, creationDate: Date(timeIntervalSinceReferenceDate: 800_000_000)),
                               style: InkStyle(width: 3), id: id(100 + number))
        result.parentID = parent
        return result
    }

    /// Every kind of content a notebook can hold, with fixed identifiers and dates so the encoded bytes are reproducible.
    private func referenceArchive() throws -> NotebookArchive {
        let noteID = id(1), pageIDs = [id(10), id(11)]
        var note = NoteDocument(id: noteID, folderID: NotebookFolder.homeID, title: "Swift reference", pageIDs: pageIDs,
                                createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000), updatedAt: Date(timeIntervalSinceReferenceDate: 800_000_100))
        note.favorite = true
        var first = NotePage(id: pageIDs[0], noteID: noteID, index: 0, format: .a4Portrait, template: .ruled, drawingResourceID: "page1.drawing")
        first.text = "Typed page text"; first.bookmark = true; first.revision = 3; first.drawingRevision = 2
        first.modifiedAt = Date(timeIntervalSinceReferenceDate: 800_000_050)
        var sticky = PageElement(kind: .stickyNote); sticky.id = id(20); sticky.text = "Remember"; sticky.x = 40; sticky.y = 200; sticky.width = 180; sticky.height = 120
        sticky.richTextRTF = Data("{\\rtf1\\ansi Remember}".utf8); sticky.fillColorHex = "#FFE66D"; sticky.rotation = 0.1; sticky.collapsed = false; sticky.stickyCornerRadius = 8
        var child = PageElement(kind: .rectangle); child.id = id(21); child.text = ""; child.x = 50; child.y = 210; child.width = 60; child.height = 30; child.parentID = sticky.id; child.strokeColorHex = "#315BB1"
        var text = PageElement(kind: .text); text.id = id(22); text.text = "Hello"; text.x = 20; text.y = 20; text.width = 100; text.height = 40; text.textFontSize = 16; text.textColorHex = "#202725"
        var image = PageElement(kind: .image); image.id = id(23); image.text = ""; image.resource = "image.png"; image.x = 30; image.y = 400; image.width = 50; image.height = 50
        first.elements = [sticky, child, text, image]
        var second = NotePage(id: pageIDs[1], noteID: noteID, index: 1, format: .a4Portrait, template: .dotted, drawingResourceID: "page2.drawing")
        second.backgroundID = "document.pdf"; second.pdfIndex = 0; second.width = 300; second.height = 400
        let ink = InkDrawing(strokes: [stroke(.pen, number: 1), stroke(.monoline, number: 2), stroke(.fountainPen, number: 3), stroke(.marker, number: 4),
                                       stroke(.pencil, number: 5), stroke(.pen, number: 6, parent: sticky.id)])
        let archive = NotebookArchive(note: note, pages: [first, second], resources: [
            "page1.drawing": try ink.encodedData(), "page2.drawing": try InkDrawing().encodedData(), "image.png": Self.png, "document.pdf": Self.pdf])
        try archive.validate()
        return archive
    }

    func testAppWrittenReferenceArchiveMatchesCommittedFixture() throws {
        let data = try CloudSync.encode(try referenceArchive())
        let url = Self.fixtures.appendingPathComponent("swift-archive.json")
        if ProcessInfo.processInfo.environment["REGENERATE_FIXTURES"] == "1" {
            try FileManager.default.createDirectory(at: Self.fixtures, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        let committed = try Data(contentsOf: url)
        XCTAssertEqual(data, committed, "The app's archive format changed. Regenerate fixtures/swift-archive.json (TEST_RUNNER_REGENERATE_FIXTURES=1) and run `npm test` in server/ to confirm the MCP still reads it.")
        let decoded = try JSONDecoder().decode(NotebookArchive.self, from: committed)
        try decoded.validate()
        XCTAssertEqual(decoded.pages.count, 2)
    }

    func testArchiveWrittenByTheMCPDecodesAndValidates() throws {
        let archive = try JSONDecoder().decode(NotebookArchive.self, from: Data(contentsOf: Self.fixtures.appendingPathComponent("node-archive.json")))
        try archive.validate()
        XCTAssertEqual(archive.note.title, "Interop fixture")
        XCTAssertEqual(archive.pages.count, 3)
        XCTAssertEqual(archive.pages[0].template, .grid)
        XCTAssertEqual(archive.pages[0].bookmark, true)
        XCTAssertEqual(Set(archive.pages[0].elements?.map(\.kind) ?? []), Set([.text, .rectangle, .ellipse, .line, .arrow, .highlight, .stickyNote, .image]))
        // Every ink type the MCP can draw must decode as native ink.
        let drawing = try InkDrawing(data: XCTUnwrap(archive.resources[archive.pages[0].drawingResourceID]))
        XCTAssertEqual(drawing.strokes.count, 5)
        for page in archive.pages { _ = try InkDrawing(data: XCTUnwrap(archive.resources[page.drawingResourceID])) }
        XCTAssertNotNil(archive.pages[1].backgroundID)
    }
}
