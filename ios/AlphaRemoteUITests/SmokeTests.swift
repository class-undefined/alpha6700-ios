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
