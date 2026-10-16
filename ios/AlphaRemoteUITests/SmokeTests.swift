import XCTest

final class SmokeTests: XCTestCase {
  @MainActor func testDisconnectedNavigationAndConnectionForm() throws {
    let app = XCUIApplication()
    app.launch()
    XCTAssertTrue(app.buttons["shutter"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["shutter"].isEnabled)
    save(app, "01-viewfinder")
    app.buttons["connectionBadge"].firstMatch.tap()
    XCTAssertTrue(app.textFields["cameraHost"].waitForExistence(timeout: 4))
    XCTAssertFalse(app.buttons["connectCamera"].isEnabled)
    save(app, "02-connection")
    app.buttons["完成"].firstMatch.tap()
    for (label, name) in [("素材", "03-library"), ("参数", "04-properties"), ("相机", "05-camera")] {
      app.tabBars.buttons[label].tap()
      save(app, name)
    }
  }
  @MainActor private func save(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}

extension SmokeTests {
  @MainActor func testPhotoPagingZoomAndClearPreview() throws {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-fixtures"]
    app.launch()
    app.tabBars.buttons["素材"].tap()
    let first = app.buttons["media-1"]
    XCTAssertTrue(first.waitForExistence(timeout: 8))
    first.tap()
    let title = app.staticTexts["photoTitle"]
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    XCTAssertEqual(title.label, "TEST01.JPG")
    let quality = app.staticTexts["photoQuality"]
    XCTAssertTrue(waitFor(quality, contains: "2400 × 1600"))
    let surface = app.scrollViews["zoomPhoto-1"]
    XCTAssertTrue(surface.exists)
    surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.46)).doubleTap()
    let zoomed = NSPredicate(format: "value == %@", "3.0×")
    XCTAssertTrue(expectation(for: zoomed, evaluatedWith: surface).wait(timeout: 3))
    surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.46)).doubleTap()
    XCTAssertTrue(
      expectation(for: NSPredicate(format: "value == %@", "1.0×"), evaluatedWith: surface).wait(
        timeout: 3))
    surface.swipeLeft()
    XCTAssertTrue(waitFor(title, contains: "TEST02.JPG"))
    XCTAssertTrue(waitFor(quality, contains: "2400 × 1600"))
    XCTAssertGreaterThan(
      app.images["photoImage-2"].frame.width, app.frame.width * 0.9,
      "Replacing a thumbnail must refit the large image to screen width")
    app.scrollViews["zoomPhoto-2"].swipeLeft()
    XCTAssertTrue(waitFor(title, contains: "TEST03.JPG"))
    app.buttons["上一张"].tap()
    XCTAssertTrue(waitFor(title, contains: "TEST02.JPG"))
    save(app, "06-photo-pager")
    app.buttons["loadOriginal"].tap()
    XCTAssertTrue(waitFor(quality, contains: "原图"))
    app.buttons["closePhotoBrowser"].tap()
    XCTAssertTrue(app.tabBars.buttons["素材"].exists)
  }
  @MainActor func testISORulerWritesSettledSelection() throws {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-fixtures"]
    app.launch()
    let iso = app.buttons["quick-\(0xD21E)"]
    XCTAssertTrue(iso.waitForExistence(timeout: 8))
    iso.tap()
    let value = app.staticTexts["cameraValue-\(0xD21E)"]
    XCTAssertTrue(value.waitForExistence(timeout: 3))
    XCTAssertTrue(value.label.contains("250"))
    let ruler = app.descendants(matching: .any).matching(identifier: "parameterRuler-\(0xD21E)")
      .firstMatch
    XCTAssertTrue(ruler.exists)
    ruler.swipeLeft()
    let changed = NSPredicate(format: "NOT label CONTAINS %@", "250")
    XCTAssertTrue(expectation(for: changed, evaluatedWith: value).wait(timeout: 4))
    save(app, "07-iso-ruler")
    XCTAssertFalse(app.sheets["设置ISO"].exists)
    app.buttons["完成"].tap()
    XCTAssertTrue(app.buttons["shutter"].exists)
  }
  @MainActor private func waitFor(_ element: XCUIElement, contains: String) -> Bool {
    expectation(for: NSPredicate(format: "label CONTAINS %@", contains), evaluatedWith: element)
      .wait(timeout: 6)
  }
}
extension XCTestExpectation {
  func wait(timeout: TimeInterval) -> Bool {
    XCTWaiter.wait(for: [self], timeout: timeout) == .completed
  }
}

extension SmokeTests {
  @MainActor func testLongPressSelectionFormatsAndBatchExport() throws {
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = ["--ui-fixtures", "--reset-export-preferences"]
    app.launch()
    app.tabBars.buttons["素材"].tap()
    let first = app.buttons["media-1"]
    let second = app.buttons["media-2"]
    XCTAssertTrue(first.waitForExistence(timeout: 8))
    first.press(forDuration: 0.6)
    XCTAssertFalse(
      app.staticTexts["photoTitle"].exists, "Long press must select without opening a photo")
    XCTAssertTrue(waitFor(app.staticTexts["mediaSelectionCount"], contains: "已选 1"))
    second.tap()
    XCTAssertTrue(waitFor(app.staticTexts["mediaSelectionCount"], contains: "已选 2"))
    first.tap()
    XCTAssertTrue(waitFor(app.staticTexts["mediaSelectionCount"], contains: "已选 1"))
    first.tap()
    save(app, "10-photo-selection")
    app.buttons["selectionExportSettings"].tap()
    app.descendants(matching: .any).matching(identifier: "exportFormat-raw").firstMatch.tap()
    app.buttons["完成"].firstMatch.tap()
    XCTAssertTrue(app.staticTexts["exportSkippedSummary"].exists)
    XCTAssertFalse(
      app.buttons["exportSelectedMedia"].isEnabled,
      "JPEG-only photos cannot be silently exported as RAW")
    app.buttons["selectionExportSettings"].tap()
    app.descendants(matching: .any).matching(identifier: "exportFormat-jpeg").firstMatch.tap()
    save(app, "11-export-settings")
    app.buttons["完成"].firstMatch.tap()
    XCTAssertTrue(app.buttons["exportSelectedMedia"].isEnabled)
    app.buttons["exportSelectedMedia"].tap()
    XCTAssertTrue(waitFor(app.staticTexts["batchExportSummary"], contains: "2/2"))
    save(app, "12-batch-export")
    app.terminate()
    app.launchArguments = ["--ui-fixtures"]
    app.launch()
    app.tabBars.buttons["相机"].tap()
    let settings = app.buttons["exportSettingsLink"]
    XCTAssertTrue(settings.waitForExistence(timeout: 5))
    XCTAssertTrue(settings.label.contains("JPEG"), "Export preference must survive relaunch")
  }
}
