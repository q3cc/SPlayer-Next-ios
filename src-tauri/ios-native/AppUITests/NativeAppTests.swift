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
    openSettings("localCache", in: app)
    reveal(app.buttons["native.import.settings"], in: app)
    app.buttons["native.import.settings"].tap()
    cancelAudioPicker(in: app)
  }

  /// 设置按 main 的分类组织，每个分类都能打开并显示对应分区
  func testSettingsCategoriesFollowMain() throws {
    guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("仅验证 iPad 设置布局") }
    let app = launch(landscape: true)
    defer { XCUIDevice.shared.orientation = .portrait }
    XCTAssertTrue(app.buttons["native.wide.settings"].waitForExistence(timeout: 10))
    app.buttons["native.wide.settings"].tap()
    let expected: [(String, String)] = [
      ("general", "备份与重置"), ("appearance", "主题与颜色"), ("player", "播放音源"), ("lyric", "内容样式"),
      ("services", "媒体控制"), ("localCache", "本地音乐"), ("plugins", "插件管理"),
      ("other", "平台账号"), ("about", "特别致谢"),
    ]
    for (id, text) in expected {
      openSettings(id, in: app)
      let marker = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text))
        .firstMatch
      XCTAssertTrue(marker.waitForExistence(timeout: 5), "\(id) 缺少 \(text)\n" + app.debugDescription)
      capture(app, "settings-" + id)
    }
    openSettings("appearance", in: app)
    let coverLayout = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '封面布局'"))
      .firstMatch
    let keepAwake = app.staticTexts["保持屏幕常亮"]
    let apple = app.buttons["native.settings.playerStyle.am"]
    let original = app.buttons["native.settings.playerStyle.original"]
    reveal(apple, in: app)
    apple.tap()
    reveal(keepAwake, in: app)
    XCTAssertFalse(coverLayout.exists)
    capture(app, "settings-appearance-am")
    // 已在顶部时继续下滑会收起设置 sheet，回到可点即停
    for _ in 0..<5 where !(original.exists && original.isHittable) { app.swipeDown() }
    original.tap()
    reveal(coverLayout, in: app)
    capture(app, "settings-appearance-original")
  }

  /// 顶栏进入听歌识曲：可取消收听，完整一次采集后必须落到结果或明确提示
  func testRecognitionListensAndFinishes() throws {
    let app = launch(landscape: true)
    defer { XCUIDevice.shared.orientation = .portrait }
    let entry = app.buttons["native.recognition"]
    XCTAssertTrue(entry.waitForExistence(timeout: 10))
    entry.tap()
    let start = app.buttons["native.recognition.start"]
    let phase = app.staticTexts["native.recognition.phase"]
    XCTAssertTrue(start.waitForExistence(timeout: 5))
    capture(app, "recognition-idle")
    start.tap()
    let message = app.staticTexts["native.recognition.message"]
    if message.waitForExistence(timeout: 3), message.label == "未找到可用的音频设备" {
      capture(app, "recognition-no-input")
      throw XCTSkip("模拟器没有麦克风输入，需在 macOS 隐私设置中允许“模拟器”使用麦克风")
    }
    XCTAssertTrue(
      app.staticTexts["正在收听…"].waitForExistence(timeout: 5), app.debugDescription)
    capture(app, "recognition-capturing")
    app.buttons["native.recognition.cancel"].tap()
    XCTAssertTrue(start.waitForExistence(timeout: 5))
    XCTAssertEqual(phase.label, "识别正在播放的音乐")
    start.tap()
    XCTAssertTrue(app.buttons["native.recognition.cancel"].waitForExistence(timeout: 5))
    let candidate = app.descendants(matching: .any)["native.recognition.candidate"].firstMatch
    let deadline = Date().addingTimeInterval(60)
    while Date() < deadline && !start.exists && !candidate.exists {
      Thread.sleep(forTimeInterval: 1)
    }
    XCTAssertTrue(start.exists || candidate.exists, "识曲 60 秒内未结束：" + phase.label)
    print("RECOGNITION_RESULT", message.exists ? message.label : "候选结果")
    capture(app, "recognition-finished")
  }

  /// 竖屏设置只走底部标签：顶栏不重复显示搜索和设置，设置页不显示顶栏
  func testPortraitSettingsLayout() throws {
    guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("仅验证 iPad 竖屏设置") }
    let app = launch()
    XCTAssertTrue(app.tabBars.buttons["设置"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["native.wide.settings"].exists)
    XCTAssertFalse(app.buttons["返回"].exists)
    app.tabBars.buttons["设置"].tap()
    capture(app, "portrait-tab-settings")
    XCTAssertFalse(app.buttons["native.recognition"].exists)
    openSettings("appearance", in: app)
    XCTAssertTrue(app.staticTexts["主题与颜色"].waitForExistence(timeout: 5))
    capture(app, "portrait-tab-appearance")
    openSettings("player", in: app)
    XCTAssertTrue(app.staticTexts["播放控制"].waitForExistence(timeout: 5))
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
    XCTAssertFalse(app.textFields["native.search.input"].exists)
    app.tabBars.buttons["设置"].tap()
    openSettings("localCache", in: app)
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
    openSettings("localCache", in: app)
    app.buttons["native.import.settings"].tap()
    cancelAudioPicker(in: app)
  }

  /// 静止帧仍须真正完成 Metal 绘制，不能以空背景通过界面测试
  func testFluidDrawsAndToolsOpen() {
    let app = importedPlayer()
    XCTAssertTrue(app.otherElements["native.fluid.rendered"].waitForExistence(timeout: 15))
    capture(app, "fluid-rendered")
    for name in ["均衡器", "变速 / 变调", "AB 循环", "定时关闭"] {
      app.buttons["播放器选项"].tap()
      app.buttons[name].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
      XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 5))
      capture(app, "control-" + name.replacingOccurrences(of: "/", with: "-"))
      app.buttons["完成"].tap()
    }
  }

  /// 每项播放器测试都通过真实文件选择器建立自己的测试歌曲
  private func importedPlayer() -> XCUIApplication {
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
    let ready = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "hittable == true"), object: song)
    XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed, app.debugDescription)
    capture(app, "before-real-play")
    song.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).tap()
    let playback = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == %@", "暂停"),
      object: app.buttons["native.wide.playPause"])
    XCTAssertEqual(XCTWaiter.wait(for: [playback], timeout: 10), .completed, app.debugDescription)
    app.buttons["native.wide.playPause"].tap()
    app.buttons["native.wide.nowPlaying"].tap()
    XCTAssertTrue(app.staticTexts["native.player.title"].waitForExistence(timeout: 10))
    XCTAssertFalse(
      app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '流体渲染失败'")).firstMatch.exists)
    capture(app, "native-local-player")
    return app
  }

  /// 经系统文件选择器导入后，歌曲行空白区可播放且原生播放器进度真实前进
  func testSelectAudioFileImportsAndCanPlay() {
    let app = importedPlayer()
    app.buttons["播放器选项"].tap()
    app.buttons["导入歌词"].tap()
    let lyricFile = app.descendants(matching: .any).matching(
      NSPredicate(format: "label CONTAINS 'SPlayerLyricsTest'")
    ).firstMatch
    XCTAssertTrue(lyricFile.waitForExistence(timeout: 10))
    lyricFile.tap()
    let lyricOpen = app.buttons.matching(NSPredicate(format: "label == 'Open' OR label == '打开'"))
      .firstMatch
    if lyricOpen.waitForExistence(timeout: 2) { lyricOpen.tap() }
    app.sliders["播放进度"].adjust(toNormalizedSliderPosition: 0)
    for style in ["Apple Music", "Next 原版"] {
      app.buttons["播放器选项"].tap()
      app.buttons[style].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
      let toggle = app.buttons["native.player.lyricsToggle"]
      let transport = app.buttons["native.player.playPause"]
      if style == "Next 原版"
        && app.descendants(matching: .any)["native.lyrics.stage"].firstMatch.exists
      {
        toggle.tap()
      }
      let before = toggle.frame
      let playBefore = transport.frame
      capture(app, "player-\(style)-cover")
      toggle.tap()
      XCTAssertTrue(
        app.descendants(matching: .any)["native.lyrics.stage"].firstMatch.waitForExistence(
          timeout: 5))
      if style == "Apple Music" {
        let reveal = app.buttons["native.player.revealControls"]
        XCTAssertTrue(reveal.waitForExistence(timeout: 5))
        XCTAssertEqual(reveal.label, "显示控制区")
        XCTAssertFalse(transport.exists)
        capture(app, "player-AM-immersive")
        reveal.tap()
        XCTAssertTrue(transport.waitForExistence(timeout: 5))
        XCTAssertEqual(reveal.label, "隐藏控制区")
      }
      XCTAssertEqual(toggle.frame.midY, before.midY, accuracy: 1)
      XCTAssertEqual(toggle.frame.height, before.height, accuracy: 1)
      XCTAssertEqual(transport.frame.midY, playBefore.midY, accuracy: 1)
      XCTAssertTrue(
        app.descendants(matching: .any)["native.lyrics.interlude"].firstMatch.waitForExistence(
          timeout: 5))
      capture(app, "player-\(style)-lyrics")
      app.sliders["播放进度"].adjust(toNormalizedSliderPosition: 0.75)
      let dots = app.descendants(matching: .any)["native.lyrics.interlude"].firstMatch
      let finished = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "exists == false"), object: dots)
      XCTAssertEqual(
        XCTWaiter.wait(for: [finished], timeout: 3), .completed,
        "跳转后进度：" + app.staticTexts["native.player.position"].label)
      app.sliders["播放进度"].adjust(toNormalizedSliderPosition: 0)
      XCTAssertTrue(
        app.descendants(matching: .any)["native.lyrics.interlude"].firstMatch.waitForExistence(
          timeout: 5))
      toggle.tap()
      XCTAssertEqual(toggle.frame.midY, before.midY, accuracy: 1)
      if style == "Apple Music" {
        app.buttons["native.player.queueButton"].tap()
        XCTAssertTrue(app.staticTexts["接下来播放"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["播放队列"].exists)
        capture(app, "player-AM-inline-queue")
        app.buttons["native.player.queueButton"].tap()
      }
      XCUIDevice.shared.orientation = .landscapeLeft
      let landscapeY = toggle.frame.midY
      toggle.tap()
      XCTAssertTrue(
        app.descendants(matching: .any)["native.lyrics.stage"].firstMatch.waitForExistence(
          timeout: 5))
      XCTAssertEqual(toggle.frame.midY, landscapeY, accuracy: 1)
      capture(app, "player-\(style)-landscape")
      toggle.tap()
      XCTAssertFalse(app.descendants(matching: .any)["native.lyrics.stage"].firstMatch.exists)
      if style == "Next 原版" {
        Thread.sleep(forTimeInterval: 5.5)
        XCTAssertFalse(app.buttons["native.player.playPause"].isHittable)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["native.player.playPause"].isHittable)
      }
      XCUIDevice.shared.orientation = .portrait
    }
  }

  /// 下拉取消仍留在播放器，跨过阈值后恢复之前的页面与位置
  func testPlayerDragRevealsPreviousPage() {
    let app = importedPlayer()
    app.buttons["收起播放器"].tap()
    let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'SPlayerImportTest'"))
      .firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 5))
    let previousFrame = row.frame
    XCUIDevice.shared.orientation = .landscapeLeft
    capture(app, "drag-underlying-page")
    app.buttons["native.wide.nowPlaying"].tap()
    let handle = app.buttons["收起播放器"]
    XCTAssertTrue(handle.waitForExistence(timeout: 5))
    let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    start.press(
      forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 20)),
      withVelocity: .slow, thenHoldForDuration: 1)
    XCTAssertTrue(handle.exists)
    capture(app, "drag-cancelled-player")
    print("DRAG_REVEAL_CAPTURE")
    start.press(
      forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 220)),
      withVelocity: .slow, thenHoldForDuration: 8)
    XCTAssertTrue(app.buttons["native.wide.nowPlaying"].waitForExistence(timeout: 5))
    XCUIDevice.shared.orientation = .portrait
    XCTAssertEqual(row.frame.minY, previousFrame.minY, accuracy: 1)
    capture(app, "drag-restored-page")
  }

  /// 窄屏设置折叠为分类列表，宽屏常驻左侧栏；两种形态都通过分类入口进入详情
  private func openSettings(_ id: String, in app: XCUIApplication) {
    let back = app.navigationBars.buttons["全局设置"]
    if back.exists && back.isHittable { back.tap() }
    let entries = app.buttons.matching(identifier: "native.settings.category." + id)
    XCTAssertTrue(entries.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
    // 齿轮弹层盖在设置标签页之上时两层都有分类入口，取最上层
    entries.element(boundBy: entries.count - 1).tap()
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
