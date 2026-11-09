import XCTest
import UIKit

@MainActor
final class DesignInteractionTests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-nativeTools", "NO", "-inkTool", "pen"]
        app.launch()
        let library = app.buttons["workspace.library"]
        if library.waitForExistence(timeout: 5) { library.tap() }
        XCTAssertTrue(app.buttons["library.create"].waitForExistence(timeout: 10))
    }

    override func tearDownWithError() throws {
        if let testRun, testRun.failureCount > 0 {
            screenshot("Screen on failure")
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Hierarchy on failure"; hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        app.terminate()
    }

    func testLibrarySelectionClearsAcrossFilters() throws {
        let notebook = try createNotebook()
        app.buttons["library.select"].tap()
        app.buttons[notebook].tap()
        XCTAssertTrue(app.buttons["library.move"].waitForExistence(timeout: 5))
        screenshot("Selection before filter change")

        selectFilter("Favorites")
        XCTAssertEqual(app.buttons["library.select"].label, "Select")
        XCTAssertFalse(app.buttons["library.move"].exists)
        screenshot("Favorites after resetting selection")

        selectFilter("Documents")
        XCTAssertEqual(app.buttons["library.select"].label, "Select")
        XCTAssertFalse(app.buttons["library.move"].exists)
        app.buttons[notebook].tap()
        XCTAssertTrue(app.buttons["editor.actions"].waitForExistence(timeout: 10), "Tapping a notebook must open it after changing the filter")
        screenshot("Notebook opened after filter change")
    }

    func testUnmatchedSearchShowsSearchState() throws {
        _ = try createNotebook()
        screenshot("Library before searching")
        let search = app.searchFields.firstMatch
        if !search.isHittable { app.swipeDown() }
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("opennotes-ui-no-match-\(UUID().uuidString)")
        XCTAssertTrue(app.staticTexts["No results"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["A page for your ideas"].exists)
        screenshot("Search with no results")
    }

    func testInstrumentSettingsAndCaptureActions() throws {
        let notebook = try createNotebook()
        app.buttons[notebook].tap()
        XCTAssertTrue(app.buttons["editor.actions"].waitForExistence(timeout: 10))
        screenshot("Editor before settings")
        for label in ["Pen", "Highlighter", "Eraser", "Lasso", "Instrument settings"] {
            XCTAssertGreaterThanOrEqual(app.buttons[label].frame.width, 44)
            XCTAssertGreaterThanOrEqual(app.buttons[label].frame.height, 44)
        }
        app.buttons["Instrument settings"].tap()
        XCTAssertTrue(app.navigationBars["Instrument"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.sliders["Stroke width"].isHittable)
        screenshot("Instrument settings")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["editor.actions"].isHittable)

        openPageCapture()
        for identifier in ["capture.copy", "capture.insert", "capture.share"] {
            XCTAssertTrue(app.buttons[identifier].isHittable, "Control \(identifier) must remain accessible")
        }
        screenshot("Capture before copying")
        app.buttons["capture.copy"].tap()
        XCTAssertTrue(app.buttons["editor.actions"].waitForExistence(timeout: 5))
        waitUntilDismissed(app.buttons["capture.copy"])
        screenshot("Editor after copying")

        openPageCapture()
        app.buttons["capture.insert"].tap()
        let done = app.buttons["editor.mode.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        screenshot("Capture placement before finishing")
        done.tap()
        XCTAssertFalse(done.exists)
        XCTAssertTrue(app.buttons["editor.actions"].isHittable)
        screenshot("Editor after finishing placement")

        app.buttons["editor.actions"].tap()
        app.buttons["Crop / manage images"].tap()
        XCTAssertTrue(app.buttons["Edit image 1"].waitForExistence(timeout: 5))
        app.buttons["Edit image 1"].tap()
        XCTAssertTrue(app.navigationBars["Edit image"].waitForExistence(timeout: 5))
        let crop = app.switches["Crop"]
        if crop.switches.firstMatch.exists { crop.switches.firstMatch.tap() }
        else { crop.tap() }
        XCTAssertTrue(app.sliders["Left"].waitForExistence(timeout: 5))
        for label in ["Left", "Top", "Right", "Bottom"] {
            reveal(app.sliders[label])
            XCTAssertTrue(app.sliders[label].isHittable)
            XCTAssertTrue(app.staticTexts[label].exists)
        }
        screenshot("Cropping with visible labels")
        app.navigationBars["Edit image"].buttons["Cancel"].tap()
        if done.waitForExistence(timeout: 5) { done.tap() }

        openPageCapture()
        let share = app.buttons["capture.share"]
        share.tap()
        let activity = app.otherElements["ActivityListView"]
        XCTAssertTrue(activity.waitForExistence(timeout: 10))
        XCTAssertTrue(activity.buttons["header.closeButton"].waitForExistence(timeout: 10))
        XCTAssertTrue(activity.buttons["header.closeButton"].isHittable)
        XCTAssertTrue(activity.collectionViews["activityCollectionView"].exists)
        let caption = activity.otherElements["LP.CaptionBar.TopCaption"]
        XCTAssertTrue(caption.waitForExistence(timeout: 5))
        XCTAssertTrue(caption.label.contains("Capture"))
        XCTAssertEqual(app.alerts.count, 0, "Sharing must open the system sheet without errors")
        screenshot("System sheet after sharing the capture")
    }

    func testAnnotationEditingDoesNotDeleteTheRow() throws {
        let notebook = try createNotebook()
        app.buttons[notebook].tap()
        XCTAssertTrue(app.buttons["editor.actions"].waitForExistence(timeout: 10))
        app.buttons["editor.actions"].tap()
        app.buttons["editor.sticky.add"].tap()
        let text = app.textViews["Sticky note text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        text.tap(); text.typeText("Annotation to preserve")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["editor.actions"].waitForExistence(timeout: 5))
        app.buttons["editor.actions"].tap()
        app.buttons["Page annotations"].tap()
        XCTAssertTrue(app.staticTexts["Annotation to preserve"].waitForExistence(timeout: 5))
        screenshot("Annotation before editing")
        app.buttons["Edit"].tap()
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        XCTAssertEqual(text.value as? String, "Annotation to preserve")
        app.navigationBars["Sticky note"].buttons["Cancel"].tap()
        app.buttons["editor.actions"].tap()
        app.buttons["Page annotations"].tap()
        XCTAssertTrue(app.staticTexts["Annotation to preserve"].waitForExistence(timeout: 5), "Editing must not trigger the Delete button in the same row")
        screenshot("Annotation preserved after canceling the edit")
        app.buttons["Delete this annotation"].tap()
        XCTAssertTrue(app.staticTexts["No annotations on this page"].waitForExistence(timeout: 5))
    }

    func testReplacingImportedPaperCanBeCancelled() throws {
        guard #available(iOS 16.4, *) else { throw XCTSkip("Opening URLs from XCTest requires iOS 16.4") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Reference paper \(UUID().uuidString).pdf")
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600)).pdfData { context in
            context.beginPage()
            ("Document to preserve" as NSString).draw(at: CGPoint(x: 40, y: 60), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
        }
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        app.open(url)
        XCTAssertTrue(app.buttons["editor.actions"].waitForExistence(timeout: 10))
        app.buttons["editor.actions"].tap()
        app.buttons["Change paper"].tap()
        XCTAssertTrue(app.buttons["Ruled"].waitForExistence(timeout: 5))
        screenshot("PDF paper before replacement")
        app.buttons["Ruled"].tap()
        XCTAssertTrue(app.buttons["Replace background"].waitForExistence(timeout: 5))
        screenshot("Confirmation before replacing the PDF background")
        // iPad confirmation popovers omit the Cancel row and dismiss on an outside tap.
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists { cancel.tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.95)).tap() }
        XCTAssertTrue(app.buttons["Ruled"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Ruled"].isSelected)
        app.buttons["Ruled"].tap()
        XCTAssertTrue(app.buttons["Replace background"].waitForExistence(timeout: 5), "Canceling must preserve the imported background and request confirmation again")
        app.buttons["Replace background"].tap()
        XCTAssertTrue(app.buttons["editor.actions"].waitForExistence(timeout: 5))
        app.buttons["editor.actions"].tap()
        app.buttons["Change paper"].tap()
        XCTAssertTrue(app.buttons["Ruled"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Ruled"].isSelected)
        screenshot("Ruled paper after confirmed replacement")
    }

    func testAccessibility5SelectionAndCaptureRemainReachable() throws {
        app.terminate()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let library = app.buttons["workspace.library"]
        if library.waitForExistence(timeout: 5) { library.tap() }
        XCTAssertTrue(app.buttons["library.create"].waitForExistence(timeout: 10))

        let notebook = try createNotebook()
        let selection = app.buttons["library.select"]
        reveal(selection, towardTop: true)
        selection.tap()
        XCTAssertEqual(selection.label, "Done")
        let note = app.buttons[notebook]
        reveal(note)
        note.tap()
        XCTAssertEqual(note.value as? String, "Selected")
        reveal(app.buttons["library.move"], towardTop: true)
        XCTAssertTrue(app.buttons["library.move"].isHittable)
        XCTAssertTrue(app.buttons["library.filter"].exists, "Large text must offer the compact filter")
        screenshot("AX5 selection before filter change")

        selectFilter("Favorites")
        reveal(selection, towardTop: true)
        XCTAssertEqual(selection.label, "Select")
        XCTAssertFalse(app.buttons["library.move"].exists)
        selectFilter("Documents")
        XCTAssertEqual(selection.label, "Select")
        XCTAssertFalse(app.buttons["library.move"].exists)
        reveal(note, tappingCenter: true)
        note.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["editor.actions"].waitForExistence(timeout: 10))
        waitUntilDismissed(app.keyboards.firstMatch)

        app.buttons["editor.actions"].tap()
        reveal(app.buttons["Capture an area"])
        app.buttons["Capture an area"].tap()
        let done = app.buttons["editor.mode.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertTrue(done.isHittable)
        XCTAssertEqual(done.label, "Cancel")
        XCTAssertGreaterThanOrEqual(done.frame.height, 44)
        screenshot("AX5 capture mode before cancellation")
        done.tap()
        XCTAssertFalse(done.exists)
        XCTAssertTrue(app.buttons["editor.actions"].isHittable)

        openPageCapture()
        for identifier in ["capture.copy", "capture.insert", "capture.share"] {
            let action = app.buttons[identifier]
            reveal(action)
            XCTAssertTrue(action.isHittable, "Control \(identifier) must be accessible after scrolling at AX5")
            XCTAssertGreaterThanOrEqual(action.frame.width, 44)
            XCTAssertGreaterThanOrEqual(action.frame.height, 44)
        }
        screenshot("AX5 capture actions after scrolling")
        let copy = app.buttons["capture.copy"]
        reveal(copy, towardTop: true)
        copy.tap()
        XCTAssertTrue(app.buttons["editor.actions"].waitForExistence(timeout: 5))
        waitUntilDismissed(copy)
        screenshot("AX5 editor after copying")
    }

    func testFolderBreadcrumbsMoveAndTrashRecovery() throws {
        let token = UUID().uuidString.prefix(8)
        let title = "UI notebook \(token)"
        let parent = "UI Folder \(token)", child = "1"
        let parentCard = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "library.folder.", parent)).firstMatch
        let childCard = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "library.folder.", child)).firstMatch
        let notebook = try createNotebook()
        try renameNotebook(notebook, to: title)

        createFolder(named: parent)
        reveal(parentCard); parentCard.tap()
        createFolder(named: child)
        reveal(childCard); childCard.tap()
        let parentBreadcrumb = app.scrollViews.buttons[parent].firstMatch
        reveal(parentBreadcrumb, towardTop: true)
        XCTAssertGreaterThanOrEqual(parentBreadcrumb.frame.height, 44)
        let childBreadcrumb = app.scrollViews.buttons[child].firstMatch
        XCTAssertGreaterThanOrEqual(childBreadcrumb.frame.width, 44)
        XCTAssertGreaterThanOrEqual(childBreadcrumb.frame.height, 44)
        screenshot("Nested folders and breadcrumbs")
        parentBreadcrumb.tap()
        XCTAssertTrue(childCard.waitForExistence(timeout: 5))
        let rootBreadcrumb = app.scrollViews.buttons["Documents"].firstMatch
        XCTAssertGreaterThanOrEqual(rootBreadcrumb.frame.height, 44)
        rootBreadcrumb.tap()

        let select = app.buttons["library.select"]
        reveal(select, towardTop: true)
        XCTAssertGreaterThanOrEqual(select.frame.height, 44)
        select.tap()
        let note = app.buttons[notebook]
        reveal(note); note.tap()
        XCTAssertEqual(note.value as? String, "Selected")
        let move = app.buttons["library.move"]
        reveal(move, towardTop: true)
        XCTAssertGreaterThanOrEqual(move.frame.height, 44)
        move.tap()
        XCTAssertTrue(app.navigationBars["Move to…"].waitForExistence(timeout: 5))
        let destination = app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", "\(parent) / \(child)")).firstMatch
        reveal(destination); destination.tap()
        waitUntilDismissed(app.navigationBars["Move to…"])
        waitUntilDismissed(note)
        XCTAssertEqual(select.label, "Select")
        reveal(parentCard, towardTop: true); parentCard.tap()
        reveal(childCard); childCard.tap()
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        XCTAssertEqual(note.label, title)
        screenshot("Notebook moved into the subfolder")

        let actions = app.buttons["Actions for \(title)"]
        reveal(actions); actions.tap()
        app.buttons["Move to Trash"].tap()
        XCTAssertTrue(app.staticTexts["Move this notebook to Trash?"].waitForExistence(timeout: 5))
        app.buttons["Move to Trash"].tap()
        waitUntilDismissed(note)
        selectFilter("Trash")
        reveal(note, tappingCenter: true)
        XCTAssertFalse(note.isEnabled)
        XCTAssertEqual(note.value as? String, "In Trash")
        XCTAssertFalse(select.exists)
        XCTAssertFalse(move.exists)
        screenshot("Trash with explicit status and disabled card")
        reveal(actions); actions.tap()
        XCTAssertTrue(app.buttons["Restore notebook"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Move to…"].exists)
        app.buttons["Restore notebook"].tap()
        waitUntilDismissed(note)

        selectFilter("Documents")
        reveal(parentCard); parentCard.tap()
        reveal(childCard); childCard.tap()
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        XCTAssertTrue(note.isEnabled)
        screenshot("Notebook restored in its subfolder")
        reveal(note, tappingCenter: true)
        note.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["editor.actions"].waitForExistence(timeout: 10))
    }

    func testSixTabsRestoreActiveAndCloseByName() throws {
        let token = UUID().uuidString.prefix(8)
        var entries: [(id: String, title: String)] = []
        for index in 1...6 {
            let id = try createNotebook()
            let title = "Onglet \(index) UI \(token)"
            try renameNotebook(id, to: title)
            entries.append((id, title))
        }
        let first = try XCTUnwrap(entries.first), last = try XCTUnwrap(entries.last)
        reveal(app.buttons[last.id]); app.buttons[last.id].tap()
        XCTAssertTrue(app.buttons["editor.actions"].waitForExistence(timeout: 10))
        let firstTab = app.buttons[first.title], lastTab = app.buttons[last.title]
        let tabs = app.scrollViews.containing(.button, identifier: first.title).firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 5), "This flow requires visible tabs on an iPad at regular size")
        waitForSelectedTab(lastTab)
        for entry in entries { XCTAssertTrue(app.buttons[entry.title].exists) }
        screenshot("Six tabs with the last active and visible")

        for tab in [firstTab, lastTab] {
            for _ in 0..<10 {
                let frame = tab.frame, viewport = tabs.frame
                if !frame.isEmpty && viewport.contains(frame) { break }
                let towardBeginning = frame.midX < viewport.midX
                let start = tabs.coordinate(withNormalizedOffset: CGVector(dx: towardBeginning ? 0.25 : 0.75, dy: 0.75))
                let end = tabs.coordinate(withNormalizedOffset: CGVector(dx: towardBeginning ? 0.75 : 0.25, dy: 0.75))
                // Hold before lifting so momentum does not skip the requested tab.
                start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
            }
            XCTAssertFalse(tab.frame.isEmpty)
            XCTAssertTrue(tabs.frame.contains(tab.frame))
            XCTAssertTrue(tab.isHittable)
            tab.tap()
            waitForSelectedTab(tab)
        }
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["editor.actions"].waitForExistence(timeout: 10))
        waitForSelectedTab(lastTab)
        for entry in entries { XCTAssertTrue(app.buttons[entry.title].exists) }
        screenshot("Active tab visible after restoration")

        let close = app.buttons["Close \(last.title)"]
        XCTAssertTrue(close.isHittable)
        XCTAssertGreaterThanOrEqual(close.frame.width, 44)
        XCTAssertGreaterThanOrEqual(close.frame.height, 44)
        close.tap()
        waitUntilDismissed(lastTab)
        for entry in entries.dropLast() { XCTAssertTrue(app.buttons[entry.title].exists) }
        screenshot("Tab closed by name and other notebooks preserved")
        app.buttons["workspace.library"].tap()
        reveal(app.buttons[last.id], tappingCenter: true)
        XCTAssertTrue(app.buttons[last.id].exists, "Closing a tab must keep the notebook in the library")
    }

    private func renameNotebook(_ identifier: String, to title: String) throws {
        let note = app.buttons[identifier]
        reveal(note, tappingCenter: true)
        let frame = note.frame
        // Untitled notebooks share a name; use the explicit menu next to this card.
        let actions = app.buttons.matching(identifier: "Actions for \(note.label)").allElementsBoundByIndex.first {
            let menu = $0.frame
            return menu.midX >= frame.minX && menu.midX <= frame.maxX && menu.midY > frame.maxY && menu.midY < frame.maxY + 80
        }
        let menu = try XCTUnwrap(actions)
        reveal(menu); menu.tap()
        XCTAssertTrue(app.buttons["Rename"].waitForExistence(timeout: 5))
        app.buttons["Rename"].tap()
        let alert = app.alerts["Rename notebook"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let field = alert.textFields["Title"]
        let previous = field.value as? String ?? ""
        field.tap(); field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count) + title)
        alert.buttons["Save"].tap()
        waitUntilDismissed(alert)
        XCTAssertEqual(note.label, title)
    }

    private func createFolder(named name: String) {
        let create = app.buttons["Folder"]
        reveal(create, towardTop: true); create.tap()
        let field = app.textFields["Folder name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText(name)
        app.navigationBars["New folder"].buttons["Save"].tap()
        waitUntilDismissed(app.navigationBars["New folder"])
        XCTAssertTrue(app.buttons[name].waitForExistence(timeout: 5))
    }

    private func waitForSelectedTab(_ tab: XCUIElement) {
        let active = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true AND isHittable == true"), object: tab)
        XCTAssertEqual(XCTWaiter.wait(for: [active], timeout: 5), .completed)
    }

    private func createNotebook() throws -> String {
        selectFilter("Documents")
        let previous = Set(notebooks.allElementsBoundByIndex.map(\.identifier))
        let create = app.buttons["library.create"]
        reveal(create, towardTop: true)
        create.tap()
        XCTAssertTrue(app.buttons["library.new.confirm"].waitForExistence(timeout: 5)); app.buttons["library.new.confirm"].tap()
        XCTAssertTrue(app.buttons["editor.actions"].waitForExistence(timeout: 10))
        app.buttons["workspace.library"].tap()
        XCTAssertTrue(app.buttons["library.select"].waitForExistence(timeout: 10))
        let created = notebooks.matching(NSPredicate(format: "NOT (identifier IN %@)", argumentArray: [Array(previous)])).firstMatch
        reveal(created)
        return try XCTUnwrap(created.exists ? created.identifier : nil)
    }

    private var notebooks: XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.note."))
    }

    private func selectFilter(_ title: String) {
        let filter = app.buttons["library.filter"]
        if filter.exists { reveal(filter, towardTop: true); filter.tap(); app.buttons[title].firstMatch.tap() }
        else { app.buttons[title].firstMatch.tap() }
        if title == "Trash" { XCTAssertTrue(app.navigationBars["Trash"].waitForExistence(timeout: 5)) }
        else { XCTAssertTrue(app.buttons["library.select"].waitForExistence(timeout: 5)) }
    }

    private func reveal(_ element: XCUIElement, towardTop: Bool = false, tappingCenter: Bool = false) {
        func reached() -> Bool {
            guard element.exists else { return false }
            if tappingCenter {
                return app.frame.contains(element.frame) && element.frame.minY >= app.navigationBars.firstMatch.frame.maxY
            }
            return element.isHittable
        }
        for _ in 0..<10 {
            if reached() { return }
            let containers = app.scrollViews.allElementsBoundByIndex + app.collectionViews.allElementsBoundByIndex
            guard let scroll = containers.first(where: { $0.isHittable }) else { break }
            // Native menus can report an unclipped full-screen collection frame.
            let clippedMenu = scroll.elementType == .collectionView && scroll.frame.height >= app.frame.height
            if clippedMenu {
                let visible = scroll.buttons.allElementsBoundByIndex.filter { $0.isHittable }
                let region = visible.reduce(CGRect.null) { $0.union($1.frame) }.intersection(app.frame)
                if !region.isNull && region.height > 44 {
                    let x = (region.midX - app.frame.minX) / app.frame.width
                    let top = (region.minY + region.height * 0.2 - app.frame.minY) / app.frame.height
                    let bottom = (region.minY + region.height * 0.8 - app.frame.minY) / app.frame.height
                    let towardBeginning = element.exists ? element.frame.midY < region.midY : towardTop
                    let start = app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: towardBeginning ? top : bottom))
                    let end = app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: towardBeginning ? bottom : top))
                    start.press(forDuration: 0.05, thenDragTo: end)
                    continue
                }
            }
            let midpoint = clippedMenu ? scroll.frame.minY + scroll.frame.height * 0.25 : scroll.frame.midY
            let towardBeginning = element.exists ? element.frame.midY < midpoint : towardTop
            let upper = clippedMenu ? 0.15 : towardBeginning ? 0.35 : 0.45
            let lower = clippedMenu ? 0.40 : towardBeginning ? 0.55 : 0.65
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: towardBeginning ? upper : lower))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: towardBeginning ? lower : upper))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(reached(), "The requested control must be reachable by scrolling")
    }

    private func openPageCapture() {
        app.buttons["editor.actions"].tap()
        reveal(app.buttons["Capture entire page"])
        app.buttons["Capture entire page"].tap()
        XCTAssertTrue(app.navigationBars["Capture"].waitForExistence(timeout: 10))
        reveal(app.buttons["capture.copy"])
    }

    private func waitUntilDismissed(_ element: XCUIElement) {
        let disappeared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [disappeared], timeout: 5), .completed)
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
