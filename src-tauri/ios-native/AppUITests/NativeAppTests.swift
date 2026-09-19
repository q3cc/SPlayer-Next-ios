import XCTest
import UIKit

final class NativeAppTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testWideLayoutMatchesOriginalStructure() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("仅验证 iPad 宽屏布局") }
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-light", "--uitest-import"]
        app.launch()
        XCTAssertTrue(app.buttons["native.wide.nav.首页"].waitForExistence(timeout: 10))
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "SPlayer-iPad-accessibility"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        XCTAssertTrue(app.textFields["native.wide.search"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.images["SPlayer 标志"].firstMatch.exists)
        XCTAssertEqual(app.webViews.count, 0)
        XCTAssertTrue(app.buttons["native.import.wide"].exists)
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        let sidebar = app.descendants(matching: .any)["native.wide.sidebar"].firstMatch
        let bar = app.descendants(matching: .any)["native.wide.playerbar"].firstMatch
        XCTAssertTrue(sidebar.exists)
        XCTAssertTrue(bar.exists)
        XCTAssertLessThan(sidebar.frame.width, app.frame.width / 3)
        XCTAssertGreaterThan(bar.frame.width, app.frame.width * 0.9)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "SPlayer-iPad-home"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["native.wide.nav.音乐库"].tap()
        XCTAssertEqual(app.staticTexts["native.wide.pageTitle"].label, "音乐库")
        app.buttons["native.wide.settings"].tap()
        XCTAssertTrue(app.buttons["native.import.wide.settings"].exists)
        app.buttons["native.import.wide.settings"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["native.audioPicker"].firstMatch.waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "label == 'Cancel' OR label == '取消'")).firstMatch.tap()
        app.buttons["native.wide.nav.首页"].tap()

        app.buttons["native.import.wide"].tap()
        let picker = app.descendants(matching: .any)["native.audioPicker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        let audio = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'SPlayerImportTest'")).firstMatch
        XCTAssertTrue(audio.waitForExistence(timeout: 15), app.debugDescription)
        audio.tap()
        let open = app.buttons.matching(NSPredicate(format: "label == 'Open' OR label == '打开'")).firstMatch
        if open.waitForExistence(timeout: 3) { open.tap() }
        let song = app.buttons.containing(.staticText, identifier: "SPlayerImportTest").firstMatch
        XCTAssertTrue(song.waitForExistence(timeout: 15), app.debugDescription)
        app.buttons["native.wide.nav.音乐库"].tap()
        song.tap()
        let playbackStarted = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "暂停"),
            object: app.buttons["native.wide.playPause"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [playbackStarted], timeout: 10), .completed)
        let libraryScreenshot = XCTAttachment(screenshot: app.screenshot())
        libraryScreenshot.name = "SPlayer-iPad-library"
        libraryScreenshot.lifetime = .keepAlways
        add(libraryScreenshot)
        app.buttons["native.wide.nowPlaying"].tap()
        XCTAssertTrue(app.staticTexts["native.player.title"].waitForExistence(timeout: 10))
        let playerScreenshot = XCTAttachment(screenshot: app.screenshot())
        playerScreenshot.name = "SPlayer-iPad-playing"
        playerScreenshot.lifetime = .keepAlways
        add(playerScreenshot)
    }
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
