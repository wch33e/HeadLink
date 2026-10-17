import XCTest

/// Real application navigation on an unconnected simulator. No camera, video or pose fixtures.
@MainActor final class HeadLinkUITests:XCTestCase {
    private var app:XCUIApplication!
    override func setUpWithError() throws { continueAfterFailure=false }
    private func launch(savedPreferences:Bool = false) {
        app=XCUIApplication()
        app.launchArguments=["-onboarded","YES"]
        if savedPreferences {
            app.launchArguments += ["-axes","pitch","-response","smooth","-mountMode","fixed",
                "-crosshair","NO","-leftHanded","YES","-keepAwake","YES","-haptics","YES"]
        }
        app.launch()
        XCTAssertTrue(app.buttons["enterMonitor"].waitForExistence(timeout:15))
    }
    private func capture(_ name:String) {
        let attachment=XCTAttachment(screenshot:app.screenshot())
        attachment.name=name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func enterMonitor() {
        app.buttons["enterMonitor"].tap()
        XCTAssertTrue(app.buttons["openSettings"].waitForExistence(timeout:5))
    }
    private func openSettings() {
        app.buttons["openSettings"].tap()
        XCTAssertTrue(app.buttons["openReadiness"].waitForExistence(timeout:5))
    }
    private func assertSavedFollowValues() {
        let axes=app.descendants(matching:.any).matching(identifier:"axesSetting").firstMatch
        let response=app.descendants(matching:.any).matching(identifier:"responseSetting").firstMatch
        XCTAssertTrue((axes.label+String(describing:axes.value)).contains("仅上下"))
        XCTAssertTrue((response.label+String(describing:response.value)).contains("轻度平滑"))
    }
    func testRealUnconnectedLayoutAndAllSettingsPaths() throws {
        launch()
        capture("01-devices-portrait")
        enterMonitor()
        XCTAssertFalse(app.buttons["followToggle"].isEnabled)
        XCTAssertFalse(app.buttons["calibrate"].isEnabled)
        XCTAssertFalse(app.buttons["recordToggle"].isEnabled)
        capture("02-monitor-unconnected")
        openSettings(); capture("03-more")
        app.buttons["openDisplaySettings"].tap()
        XCTAssertTrue(app.switches["crosshairSetting"].waitForExistence(timeout:5))
        capture("04-display-settings")
        app.navigationBars.buttons.element(boundBy:0).tap()
        app.buttons["openLiveDiagnostics"].tap()
        XCTAssertTrue(app.buttons["重试图传恢复（不启动跟随）"].waitForExistence(timeout:5))
        XCTAssertFalse(app.buttons["重试图传恢复（不启动跟随）"].isEnabled)
        capture("05-live-diagnostics-unavailable")
        app.navigationBars.buttons.element(boundBy:0).tap()
        app.buttons["openLocalDiagnostics"].tap()
        XCTAssertTrue(app.buttons["生成脱敏诊断文件"].waitForExistence(timeout:5))
        capture("06-local-diagnostics")
        app.navigationBars.buttons.element(boundBy:0).tap()
        app.buttons["openReadiness"].tap()
        XCTAssertTrue(app.staticTexts["正式1∶1方向跟随"].waitForExistence(timeout:5))
        capture("07-readiness-real-unavailable-inputs")
    }
    func testSavedValuesSurvivePresentationAndNavigation() throws {
        launch(savedPreferences:true); enterMonitor(); openSettings()
        assertSavedFollowValues()
        for _ in 0..<3 {
            app.buttons["openDisplaySettings"].tap()
            XCTAssertTrue(app.switches["crosshairSetting"].waitForExistence(timeout:5))
            XCTAssertEqual(app.switches["crosshairSetting"].value as? String,"0")
            XCTAssertEqual(app.switches["leftHandedSetting"].value as? String,"1")
            XCTAssertEqual(app.switches["keepAwakeSetting"].value as? String,"1")
            XCTAssertEqual(app.switches["hapticsSetting"].value as? String,"1")
            app.navigationBars.buttons.element(boundBy:0).tap()
            app.buttons["closeSettings"].tap()
            XCTAssertTrue(app.buttons["openSettings"].waitForExistence(timeout:5))
            app.buttons["cameraDetails"].tap()
            XCTAssertTrue(app.buttons["enterMonitor"].waitForExistence(timeout:5))
            enterMonitor(); openSettings()
            assertSavedFollowValues()
        }
    }
    func testLandscapeControlsRemainReachable() throws {
        launch(); enterMonitor()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["openSettings"].waitForExistence(timeout:5))
        XCTAssertTrue(app.buttons["openSettings"].isHittable)
        capture("08-monitor-landscape")
        openSettings(); capture("09-more-landscape")
        XCUIDevice.shared.orientation = .portrait
    }
}
