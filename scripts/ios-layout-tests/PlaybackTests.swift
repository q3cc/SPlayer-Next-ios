import XCTest

final class PlaybackTests: XCTestCase {
    func testSiriSettingsEnable() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "top.imsyy.splayer-next.ios")
        addUIInterruptionMonitor(withDescription: "Siri permission") { alert in
            for title in ["Allow", "允许", "OK", "好"] {
                if alert.buttons[title].exists { alert.buttons[title].tap(); return true }
            }
            return false
        }
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["Open Siri settings test"].waitForExistence(timeout: 45))
        app.buttons["Open Siri settings test"].tap()
        let toggle = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ AND (elementType == %d OR elementType == %d)",
            "Siri 语音控制", XCUIElement.ElementType.switch.rawValue, XCUIElement.ElementType.button.rawValue
        )).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 15))
        for index in 0..<3 {
            toggle.tap()
            // 触发 XCTest 的系统授权弹窗处理，不直接修改授权状态。
            app.tap()
            let settled = NSPredicate { _, _ in
                toggle.exists && toggle.isEnabled
            }
            expectation(for: settled, evaluatedWith: app)
            waitForExpectations(timeout: 25)
            XCTAssertEqual(app.state, .runningForeground)
            capture("siri-toggle-\(index)")
        }
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["Open Siri settings test"].waitForExistence(timeout: 45))
        app.buttons["Open Siri settings test"].tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 15))
        XCTAssertEqual(app.state, .runningForeground)
        capture("siri-relaunch")
    }

    func testNativeEqualizerPlayback() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "top.imsyy.splayer-next.ios")
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["Play Senbonzakura test"].waitForExistence(timeout: 45))
        app.buttons["Play Senbonzakura test"].tap()
        XCTAssertTrue(app.staticTexts["Song playback verified"].waitForExistence(timeout: 150))
        app.buttons["Verify equalizer test"].tap()
        XCTAssertTrue(app.staticTexts["Equalizer playback verified"].waitForExistence(timeout: 20))
        capture("eq-live-settings")
        XCUIDevice.shared.press(.home)
        sleep(8)
        app.activate()
        app.buttons["Verify background audio test"].tap()
        XCTAssertTrue(app.staticTexts["Background audio verified"].waitForExistence(timeout: 20))
        app.buttons["Verify pause resume test"].tap()
        XCTAssertTrue(app.staticTexts["Pause resume verified"].waitForExistence(timeout: 20))
        capture("eq-background-resumed")
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSenbonzakuraPlaybackAndPiP() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "top.imsyy.splayer-next.ios")
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        let play = app.buttons["Play Senbonzakura test"]
        XCTAssertTrue(play.waitForExistence(timeout: 45))
        play.tap()
        XCTAssertTrue(app.staticTexts["Song playback verified"].waitForExistence(timeout: 150))
        capture("01-song-playing")
        app.buttons["Open lyric PiP test"].tap()
        XCTAssertTrue(app.staticTexts["Lyric PiP opened"].waitForExistence(timeout: 20))
        sleep(3)
        capture("02-pip-foreground")
        XCUIDevice.shared.press(.home)
        sleep(8)
        capture("03-pip-home")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.08)).tap()
        usleep(500_000)
        capture("03b-pip-tapped")
        sleep(25)
        capture("04-pip-home-later")
        app.activate()
        app.buttons["Verify pause resume test"].tap()
        XCTAssertTrue(app.staticTexts["Pause resume verified"].waitForExistence(timeout: 20))
        capture("05-pip-resumed")
        app.buttons["Close lyric PiP test"].tap()
        XCTAssertTrue(app.staticTexts["Playback test complete"].waitForExistence(timeout: 15))
        capture("06-pip-closed")
    }
}
