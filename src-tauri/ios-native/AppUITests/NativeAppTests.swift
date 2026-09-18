import XCTest

final class NativeAppTests: XCTestCase {
    func testNativeNavigationWithoutWebView() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["曲库"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.webViews.count, 0)
        app.tabBars.buttons["队列"].tap()
        XCTAssertTrue(app.navigationBars["播放队列"].exists)
        app.tabBars.buttons["设置"].tap()
        XCTAssertTrue(app.staticTexts["本地音乐"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
