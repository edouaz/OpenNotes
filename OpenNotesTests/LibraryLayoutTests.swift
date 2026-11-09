import XCTest
import SwiftUI
@testable import OpenNotes

@MainActor
final class LibraryLayoutTests: XCTestCase {
    func testTabsShareRowThenScrollAtMinimumWidth() {
        XCTAssertEqual(OpenNotesStyle.notebookTabWidth(availableWidth: 960, count: 1), 480)
        XCTAssertEqual(OpenNotesStyle.notebookTabWidth(availableWidth: 960, count: 2), 480)
        XCTAssertEqual(OpenNotesStyle.notebookTabWidth(availableWidth: 960, count: 3), 320)
        XCTAssertEqual(OpenNotesStyle.notebookTabWidth(availableWidth: 960, count: 4), 240)
        XCTAssertEqual(OpenNotesStyle.notebookTabWidth(availableWidth: 960, count: 8), 240)
        XCTAssertEqual(OpenNotesStyle.notebookTabWidth(availableWidth: 960, count: 2, spacing: 4), 476)
        XCTAssertEqual(OpenNotesStyle.notebookTabWidth(availableWidth: 320, count: 4), 140)
        XCTAssertEqual(OpenNotesStyle.notebookTabWidth(availableWidth: 100, count: 1), 100)
        XCTAssertEqual(OpenNotesStyle.notebookTabWidth(availableWidth: 0, count: 3), 0)
        XCTAssertEqual(OpenNotesStyle.notebookTabWidth(availableWidth: 700, count: 0), 0)
    }

    func testTabOrderRestorationAndAdjacentCloseSelection() async throws {
        let preferences = UserDefaults.standard
        let keys = ["openNotebooks", "activeNotebook"]
        let previous = keys.map { preferences.object(forKey: $0) }
        defer { for (key, value) in zip(keys, previous) { preferences.set(value, forKey: key) } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root)
        await store.load()
        var ids: [UUID] = []
        for title in ["A", "B", "C", "D"] {
            let created = await store.create(title: title)
            ids.append(try XCTUnwrap(created))
        }
        let saved = await store.flush()
        XCTAssertTrue(saved)
        let workspace = NotebookWorkspace(store: store)
        for id in ids { await workspace.select(id) }
        await workspace.select(ids[1])
        await workspace.select(ids[1])
        XCTAssertEqual(workspace.tabs, ids, "Selecting an open notebook must not move or duplicate it")
        let restored = NotebookWorkspace(store: store)
        await restored.restore()
        XCTAssertEqual(restored.tabs, ids)
        XCTAssertEqual(restored.active, ids[1])
        await restored.close(ids[1])
        XCTAssertEqual(restored.tabs, [ids[0], ids[2], ids[3]])
        XCTAssertEqual(restored.active, ids[2], "Closing the active tab selects its right neighbor")
        await restored.close(ids[0])
        XCTAssertEqual(restored.active, ids[2], "Closing an inactive tab preserves selection")
        await restored.select(ids[3])
        await restored.close(ids[3])
        XCTAssertEqual(restored.active, ids[2], "Closing the last tab selects its left neighbor")
        await restored.close(ids[2])
        XCTAssertNil(restored.active)
        XCTAssertTrue(restored.tabs.isEmpty)
        preferences.set([ids[0], UUID(), ids[1], ids[0]].map(\.uuidString), forKey: "openNotebooks")
        preferences.set(ids[1].uuidString, forKey: "activeNotebook")
        await restored.restore()
        XCTAssertEqual(restored.tabs, [ids[0], ids[1]], "Restoration removes missing and duplicate IDs without sorting")
        XCTAssertEqual(restored.active, ids[1])
    }

    func testMixedLibraryVisualMatrix() async throws {
        let preferences = UserDefaults.standard
        let keys = ["openNotebooks", "activeNotebook", "librarySort"]
        let previous = keys.map { preferences.object(forKey: $0) }
        keys.forEach { preferences.removeObject(forKey: $0) }
        defer { for (key, value) in zip(keys, previous) { preferences.set(value, forKey: key) } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LibraryStore(root: root)
        await store.load()
        let folderID = try XCTUnwrap(store.library.folders.first?.id)
        _ = store.apply(.init(kind: .createFolder, parentID: folderID, name: "Projects and ideas for next semester"))
        let titles = ["A", "Reading notes and thoughts on the landscapes of my next trip", "Voyage"]
        for (index, title) in titles.enumerated() {
            let created = await store.create(title: title, folderID: folderID)
            let id = try XCTUnwrap(created)
            store.update(id) { $0.favorite = index == 1; $0.updatedAt = Date(timeIntervalSince1970: 1_792_728_000 - Double(index * 60)) }
            if var page = store.library.firstPage(in: id) {
                page.template = index == 0 ? .grid : .ruled
                store.updatePage(page)
                _ = try await store.disk.thumbnail(page, pixels: 640)
            }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; window.rootViewController = nil; try? FileManager.default.removeItem(at: root) }
        for (size, type, scheme, name) in [
            (CGSize(width: 744, height: 1133), DynamicTypeSize.large, ColorScheme.light, "Mixed library portrait"),
            (CGSize(width: 1133, height: 744), .large, .light, "Mixed library landscape"),
            (CGSize(width: 480, height: 900), .large, .light, "Mixed library narrow window"),
            (CGSize(width: 744, height: 1133), .large, .dark, "Mixed library dark"),
            (CGSize(width: 320, height: 900), .accessibility5, .light, "Mixed library AX5")
        ] {
            window.frame = CGRect(origin: .zero, size: size)
            let host = UIHostingController(rootView: LibraryScreen().environmentObject(store)
                .environment(\.dynamicTypeSize, type).environment(\.colorScheme, scheme).tint(OpenNotesStyle.accent))
            window.rootViewController = host; window.makeKeyAndVisible()
            try await Task.sleep(nanoseconds: 500_000_000)
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            XCTAssertEqual(host.view.bounds.width, size.width, accuracy: 1)
        }
    }
}
