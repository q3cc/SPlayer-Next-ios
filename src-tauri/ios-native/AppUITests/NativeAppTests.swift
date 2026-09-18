import XCTest

final class NativeAppTests: XCTestCase {
    func testNativeNavigationWithoutWebView() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["首页"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.images["SPlayer 标志"].firstMatch.exists)
        XCTAssertEqual(app.webViews.count, 0)
        app.tabBars.buttons["音乐库"].tap()
        XCTAssertTrue(app.navigationBars["音乐库"].exists)
        app.tabBars.buttons["设置"].tap()
        XCTAssertTrue(app.staticTexts["本地音乐"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testMusicPickerCanOpenCancelAndReopen() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["native.import.home"].tap()
        let picker = app.descendants(matching: .any)["native.audioPicker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        let cancel = app.buttons.matching(NSPredicate(format: "label == 'Cancel' OR label == '取消'")).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        app.tabBars.buttons["音乐库"].tap()
        app.buttons["native.import.library"].tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        cancel.tap()
        app.tabBars.buttons["设置"].tap()
        app.buttons["native.import.settings"].tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        cancel.tap()
    }

    func testSelectAudioFileImportsAndCanPlay() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-import"]
        app.launch()
        app.buttons["native.import.home"].tap()
        let picker = app.descendants(matching: .any)["native.audioPicker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        let audio = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'SPlayerImportTest'")).firstMatch
        XCTAssertTrue(audio.waitForExistence(timeout: 15), app.debugDescription)
        audio.tap()
        let open = app.buttons.matching(NSPredicate(format: "label == 'Open' OR label == '打开'")).firstMatch
        if open.waitForExistence(timeout: 3) { open.tap() }
        let song = app.buttons.containing(.staticText, identifier: "SPlayerImportTest").firstMatch
        XCTAssertTrue(song.waitForExistence(timeout: 15), app.debugDescription)
        song.tap()
        XCTAssertTrue(app.staticTexts["native.player.title"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 10))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
