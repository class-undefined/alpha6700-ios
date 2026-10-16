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
