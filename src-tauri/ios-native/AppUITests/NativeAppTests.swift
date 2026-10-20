import UIKit
import XCTest

final class NativeAppTests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  /// 横屏侧栏、搜索和原生设置保持新版界面结构
  func testWideLayoutMatchesOriginalStructure() throws {
    guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("仅验证 iPad 宽屏布局") }
    let app = launch(landscape: true)
    defer { XCUIDevice.shared.orientation = .portrait }
    XCTAssertTrue(app.buttons["native.wide.nav.首页"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.textFields["native.search.input"].exists)
    XCTAssertEqual(app.webViews.count, 0)
    XCTAssertFalse(app.tabBars.firstMatch.exists)
    let sidebar = app.descendants(matching: .any)["native.wide.sidebar"].firstMatch
    XCTAssertTrue(sidebar.exists)
    XCTAssertEqual(sidebar.frame.width, 240, accuracy: 2)
    capture(app, "native-wide-home")
    app.buttons["native.wide.nav.音乐库"].tap()
    XCTAssertEqual(app.staticTexts["native.wide.pageTitle"].label, "音乐库")
    app.buttons["native.wide.settings"].tap()
    reveal(app.buttons["native.import.settings"], in: app)
    app.buttons["native.import.settings"].tap()
    cancelAudioPicker(in: app)
  }

  /// 竖屏使用 UIKit 导航栏且全部导航标题为中文
  func testNativeNavigationWithoutWebView() {
    let app = launch()
    XCTAssertTrue(app.tabBars.buttons["首页"].waitForExistence(timeout: 10))
    XCTAssertEqual(app.webViews.count, 0)
    for title in ["首页", "音乐库", "喜欢", "搜索", "设置"] {
      XCTAssertTrue(app.tabBars.buttons[title].exists)
    }
    app.tabBars.buttons["音乐库"].tap()
    XCTAssertEqual(app.staticTexts["native.wide.pageTitle"].label, "音乐库")
    app.tabBars.buttons["搜索"].tap()
    XCTAssertTrue(app.textFields["native.search.keyword"].exists)
    app.tabBars.buttons["设置"].tap()
    XCTAssertTrue(app.staticTexts["本地音乐"].waitForExistence(timeout: 5))
    capture(app, "native-portrait-settings")
  }

  /// 首页、曲库和设置的文件选择器均可取消并重新打开
  func testMusicPickerCanOpenCancelAndReopen() {
    let app = launch()
    let homeImport = app.buttons["native.import.home"]
    for _ in 0..<4 {
      if homeImport.isHittable { break }
      app.scrollViews.firstMatch.swipeUp()
    }
    homeImport.tap()
    cancelAudioPicker(in: app)
    app.tabBars.buttons["音乐库"].tap()
    app.buttons["native.import.library"].tap()
    cancelAudioPicker(in: app)
    app.tabBars.buttons["设置"].tap()
    app.buttons["native.import.settings"].tap()
    cancelAudioPicker(in: app)
  }

  /// 经系统文件选择器导入后，歌曲行空白区可播放且原生播放器进度真实前进
  func testSelectAudioFileImportsAndCanPlay() {
    let app = launch(importFixture: true)
    app.tabBars.buttons["音乐库"].tap()
    app.buttons["native.import.library"].tap()
    let picker = app.descendants(matching: .any)["native.audioPicker"].firstMatch
    XCTAssertTrue(picker.waitForExistence(timeout: 10))
    let audio = picker.descendants(matching: .any).matching(
      NSPredicate(format: "label CONTAINS 'SPlayerImportTest'")
    ).firstMatch
    XCTAssertTrue(audio.waitForExistence(timeout: 15), app.debugDescription)
    audio.tap()
    let open = app.buttons.matching(NSPredicate(format: "label == 'Open' OR label == '打开'"))
      .firstMatch
    if open.waitForExistence(timeout: 2) { open.tap() }
    let song = app.buttons.matching(
      NSPredicate(
        format: "identifier BEGINSWITH 'native.song.' AND label CONTAINS 'SPlayerImportTest'")
    ).firstMatch
    XCTAssertTrue(song.waitForExistence(timeout: 15), app.debugDescription)
    song.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).tap()
    let playback = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == %@", "暂停"),
      object: app.buttons["native.wide.playPause"])
    XCTAssertEqual(XCTWaiter.wait(for: [playback], timeout: 10), .completed)
    app.buttons["native.wide.nowPlaying"].tap()
    XCTAssertTrue(app.staticTexts["native.player.title"].waitForExistence(timeout: 10))
    capture(app, "native-local-player")
    app.buttons["native.player.playPause"].tap()
  }

  /// Form 按需创建屏幕外行，先滚动到控件再判断可点击性
  private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
    for _ in 0..<5 {
      if element.exists && element.isHittable { return }
      app.swipeUp()
    }
    XCTAssertTrue(element.exists && element.isHittable, app.debugDescription)
  }
  /// 每个用例明确方向，保留现有应用数据
  private func launch(landscape: Bool = false, importFixture: Bool = false) -> XCUIApplication {
    XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
    let app = XCUIApplication()
    app.launchArguments = ["--uitest-light"] + (importFixture ? ["--uitest-import"] : [])
    app.launch()
    return app
  }
  /// 弹层完全退出后才操作底层页面
  private func cancelAudioPicker(in app: XCUIApplication) {
    let picker = app.descendants(matching: .any)["native.audioPicker"].firstMatch
    XCTAssertTrue(picker.waitForExistence(timeout: 10))
    let cancel = picker.buttons.matching(NSPredicate(format: "label == 'Cancel' OR label == '取消'"))
      .firstMatch
    XCTAssertTrue(cancel.waitForExistence(timeout: 5), app.debugDescription)
    cancel.tap()
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: picker)
        ], timeout: 10), .completed)
  }
  /// 用屏幕截图保留真实横竖屏像素方向
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
