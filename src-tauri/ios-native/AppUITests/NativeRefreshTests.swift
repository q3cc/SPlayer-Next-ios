import UIKit
import XCTest

final class NativeRefreshTests: XCTestCase {
  /// 原生与 Web 基准使用同一台模拟器、同一方向与像素尺寸
  func testCaptureWebReference() {
    continueAfterFailure = false
    let app = XCUIApplication(bundleIdentifier: "top.imsyy.splayer-next.ios")
    app.terminate()
    app.launch()
    XCUIDevice.shared.orientation = .landscapeLeft
    let home = app.buttons["首页"].firstMatch
    if home.waitForExistence(timeout: 20) { home.tap() }
    Thread.sleep(forTimeInterval: 5)
    capture(app, "web-landscape-home")
    XCUIDevice.shared.orientation = .portrait
    Thread.sleep(forTimeInterval: 2)
    capture(app, "web-portrait-home")
  }

  /// 真实平台搜索与完整曲目播放，检查原生引擎进度而非按钮切换
  func testNativeSearchPlaybackAndRotation() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--uitest-light", "--uitest-player-am"]
    app.launch()
    XCUIDevice.shared.orientation = .portrait
    XCTAssertTrue(app.tabBars.buttons["搜索"].waitForExistence(timeout: 15), app.debugDescription)
    XCTAssertEqual(app.webViews.count, 0)
    Thread.sleep(forTimeInterval: 3)
    capture(app, "native-portrait-home")
    app.tabBars.buttons["搜索"].tap()
    let input = app.textFields["native.search.keyword"]
    XCTAssertTrue(input.waitForExistence(timeout: 5))
    input.tap()
    input.typeText("英雄主义\n")
    let song = app.buttons["native.song.netease:2684510360"]
    XCTAssertTrue(song.waitForExistence(timeout: 35), app.debugDescription)
    let expectedTitle = song.staticTexts.firstMatch.label
    XCTAssertFalse(expectedTitle.isEmpty)
    capture(app, "native-portrait-search")
    song.tap()
    let playPause = app.buttons["native.wide.playPause"]
    let playing = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == '暂停'"), object: playPause)
    XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 35), .completed, app.debugDescription)
    app.buttons["native.wide.nowPlaying"].tap()
    XCTAssertTrue(app.staticTexts["native.player.title"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.staticTexts["native.player.title"].label, expectedTitle)
    let before = app.staticTexts["native.player.position"].label
    Thread.sleep(forTimeInterval: 3)
    XCTAssertNotEqual(app.staticTexts["native.player.position"].label, before)
    capture(app, "native-portrait-player")
    XCUIDevice.shared.orientation = .landscapeLeft
    Thread.sleep(forTimeInterval: 2)
    capture(app, "native-landscape-player")
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5)).tap()
    app.buttons["native.player.playPause"].tap()
    app.buttons["收起播放器"].tap()
    XCTAssertTrue(app.buttons["native.wide.nav.首页"].waitForExistence(timeout: 5))
    app.buttons["native.wide.nav.首页"].tap()
    capture(app, "native-landscape-home")
    app.buttons["播放队列"].firstMatch.tap()
    XCTAssertTrue(app.staticTexts[expectedTitle].firstMatch.waitForExistence(timeout: 5))
    capture(app, "native-queue")
    app.buttons["关闭"].tap()
    app.buttons["native.wide.settings"].tap()
    XCTAssertTrue(app.staticTexts["外观设置"].waitForExistence(timeout: 5))
    capture(app, "native-settings")
  }

  /// 验证有人声的在线歌词、点击跳转及竖屏歌词模式后的旋转
  func testVocalLyricsAndPortraitToggle() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--uitest-light"]
    app.launch()
    XCUIDevice.shared.orientation = .portrait
    XCTAssertTrue(app.tabBars.buttons["搜索"].waitForExistence(timeout: 15))
    app.tabBars.buttons["搜索"].tap()
    let input = app.textFields["native.search.keyword"]
    input.tap()
    input.typeText("罗生门 Follow\n")
    let song = app.buttons["native.song.netease:1456890009"]
    XCTAssertTrue(song.waitForExistence(timeout: 35), app.debugDescription)
    song.tap()
    let playing = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == '暂停'"), object: app.buttons["native.wide.playPause"])
    XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 35), .completed, app.debugDescription)
    app.buttons["native.wide.playPause"].tap()
    app.buttons["native.wide.nowPlaying"].tap()
    XCTAssertTrue(
      app.staticTexts["native.player.title"].waitForExistence(timeout: 10), app.debugDescription)
    app.sliders["播放进度"].adjust(toNormalizedSliderPosition: 0.35)
    let stage = app.descendants(matching: .any)["native.lyrics.stage"].firstMatch
    if !stage.exists { app.buttons["歌词"].tap() }
    XCTAssertTrue(stage.waitForExistence(timeout: 10), app.debugDescription)
    Thread.sleep(forTimeInterval: 2)
    capture(app, "native-vocal-portrait-lyrics")
    XCUIDevice.shared.orientation = .landscapeLeft
    Thread.sleep(forTimeInterval: 2)
    capture(app, "native-vocal-landscape-lyrics")
    let beforeSeek = app.staticTexts["native.player.position"].label
    app.buttons["native.lyric.18"].tap()
    XCTAssertNotEqual(app.staticTexts["native.player.position"].label, beforeSeek)
  }

  /// 深色模式使用启动参数域，不修改用户保存的主题偏好
  func testDarkHomeAndNavigation() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-native.appearance", "dark"]
    app.launch()
    XCUIDevice.shared.orientation = .landscapeLeft
    XCTAssertTrue(app.buttons["native.wide.nav.首页"].waitForExistence(timeout: 15))
    Thread.sleep(forTimeInterval: 2)
    capture(app, "native-dark-landscape-home")
    XCUIDevice.shared.orientation = .portrait
    XCTAssertTrue(app.tabBars.buttons["搜索"].waitForExistence(timeout: 5))
    capture(app, "native-dark-portrait-home")
  }

  /// 只生成登录二维码并离开，不替用户执行扫码授权
  func testQRCreationAndCancellation() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--uitest-light"]
    app.launch()
    XCUIDevice.shared.orientation = .portrait
    XCTAssertTrue(app.buttons["平台账号"].waitForExistence(timeout: 15))
    app.buttons["平台账号"].tap()
    XCTAssertTrue(app.buttons["扫码登录"].waitForExistence(timeout: 10))
    app.buttons["扫码登录"].tap()
    XCTAssertTrue(
      app.staticTexts["请用手机 App 扫码并确认登录"].waitForExistence(timeout: 25), app.debugDescription)
    app.buttons["完成"].tap()
    XCTAssertTrue(app.tabBars.buttons["搜索"].waitForExistence(timeout: 10))
  }

  /// 保存像素与可访问性证据，便于发现布局和命中区域问题
  private func capture(_ app: XCUIApplication, _ name: String) {
    let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    image.name = name
    image.lifetime = .keepAlways
    add(image)
    let tree = XCTAttachment(string: app.debugDescription)
    tree.name = name + "-tree"
    tree.lifetime = .keepAlways
    add(tree)
  }
}
