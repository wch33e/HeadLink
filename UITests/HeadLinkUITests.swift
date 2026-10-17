import XCTest

/// Real application navigation on an unconnected simulator. No camera, video or pose fixtures.
@MainActor final class HeadLinkUITests:XCTestCase {
    private var app:XCUIApplication!
    override func setUpWithError() throws { continueAfterFailure=false }
    private func launch() {
        XCUIDevice.shared.orientation = .portrait
        app=XCUIApplication()
        app.launchArguments=["-onboarded","YES"]
        app.launch()
        let ready=app.buttons["enterMonitor"].waitForExistence(timeout:15)
        if !ready { capture("00-launch-failure"); print(app.debugDescription) }
        XCTAssertTrue(ready)
    }
    private func capture(_ name:String) {
        // Application snapshots may keep portrait crop bounds after rotation on iOS 26.
        // Capture the real display so evidence includes the complete landscape window.
        let attachment=XCTAttachment(screenshot:XCUIScreen.main.screenshot())
        attachment.name=name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func enterMonitor() {
        app.buttons["enterMonitor"].tap()
        XCTAssertTrue(app.buttons["openSettings"].waitForExistence(timeout:5))
        assertPrimaryControlsVisible()
    }
    private func assertPrimaryControlsVisible() {
        for id in ["calibrate","followToggle","recordToggle"] {
            let button=app.buttons[id]
            XCTAssertTrue(button.exists,id)
            XCTAssertGreaterThanOrEqual(button.frame.width,44,id)
            XCTAssertGreaterThanOrEqual(button.frame.height,44,id)
            XCTAssertGreaterThanOrEqual(button.frame.minX,app.frame.minX,id)
            XCTAssertGreaterThanOrEqual(button.frame.minY,app.frame.minY,id)
            XCTAssertLessThanOrEqual(button.frame.maxX,app.frame.maxX,id)
            XCTAssertLessThanOrEqual(button.frame.maxY,app.frame.maxY,id)
        }
    }
    private func openSettings() {
        app.buttons["openSettings"].tap()
        XCTAssertTrue(app.navigationBars["更多"].waitForExistence(timeout:5))
    }
    private func tapMoreRow(_ id:String) {
        let row=app.buttons[id]
        for _ in 0..<8 {
            if row.exists && row.isHittable { row.tap(); return }
            app.swipeUp()
        }
        capture("navigation-row-unreachable-"+id); print(app.debugDescription)
        XCTFail("Existing row is not reachable: "+id)
    }
    private func returnAndReopenSettings() {
        app.navigationBars.buttons.element(boundBy:0).tap()
        XCTAssertTrue(app.buttons["closeSettings"].waitForExistence(timeout:5))
        app.buttons["closeSettings"].tap()
        XCTAssertTrue(app.buttons["openSettings"].waitForExistence(timeout:5))
        openSettings()
    }
    private func assertSavedFollowValues() {
        let axes=app.descendants(matching:.any).matching(identifier:"axesSetting").firstMatch
        let response=app.descendants(matching:.any).matching(identifier:"responseSetting").firstMatch
        XCTAssertTrue((axes.label+String(describing:axes.value)).contains("仅上下"))
        XCTAssertTrue((response.label+String(describing:response.value)).contains("轻度平滑"))
    }
    private func setSwitch(_ id:String,to value:String) {
        let item=app.switches[id]
        if item.value as? String != value {
            // SwiftUI exposes the entire settings row as the switch's AX frame; tap its control end.
            item.coordinate(withNormalizedOffset:.init(dx:0.9,dy:0.5)).tap()
        }
        let changed=XCTNSPredicateExpectation(predicate:NSPredicate(format:"value == %@",value),object:item)
        let result=XCTWaiter.wait(for:[changed],timeout:5)
        if result != .completed { capture("switch-value-failure-"+id); print(app.debugDescription) }
        XCTAssertEqual(result,.completed)
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
        tapMoreRow("openDisplaySettings")
        XCTAssertTrue(app.switches["crosshairSetting"].waitForExistence(timeout:5))
        capture("04-display-settings")
        returnAndReopenSettings()
        tapMoreRow("openLiveDiagnostics")
        XCTAssertTrue(app.buttons["重试图传恢复（不启动跟随）"].waitForExistence(timeout:5))
        XCTAssertFalse(app.buttons["重试图传恢复（不启动跟随）"].isEnabled)
        capture("05-live-diagnostics-unavailable")
        returnAndReopenSettings()
        tapMoreRow("openLocalDiagnostics")
        XCTAssertTrue(app.buttons["生成脱敏诊断文件"].waitForExistence(timeout:5))
        capture("06-local-diagnostics")
        returnAndReopenSettings()
        tapMoreRow("openReadiness")
        XCTAssertTrue(app.staticTexts["正式1∶1方向跟随"].waitForExistence(timeout:5))
        capture("07-readiness-real-unavailable-inputs")
    }
    func testSavedValuesSurvivePresentationAndNavigation() throws {
        launch(); enterMonitor(); openSettings()
        app.buttons["axesSetting"].tap(); app.buttons["仅上下"].tap()
        app.buttons["responseSetting"].tap(); app.buttons["轻度平滑"].tap()
        assertSavedFollowValues()
        tapMoreRow("openDisplaySettings")
        XCTAssertTrue(app.switches["crosshairSetting"].waitForExistence(timeout:5))
        setSwitch("crosshairSetting",to:"0")
        setSwitch("leftHandedSetting",to:"1")
        setSwitch("keepAwakeSetting",to:"1")
        setSwitch("hapticsSetting",to:"1")
        returnAndReopenSettings()
        for _ in 0..<3 {
            tapMoreRow("openDisplaySettings")
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
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["enterMonitor"].waitForExistence(timeout:15))
        enterMonitor(); openSettings(); assertSavedFollowValues()
        tapMoreRow("openDisplaySettings")
        XCTAssertTrue(app.switches["crosshairSetting"].waitForExistence(timeout:5))
        XCTAssertEqual(app.switches["crosshairSetting"].value as? String,"0")
        XCTAssertEqual(app.switches["leftHandedSetting"].value as? String,"1")
        XCTAssertEqual(app.switches["keepAwakeSetting"].value as? String,"1")
        XCTAssertEqual(app.switches["hapticsSetting"].value as? String,"1")
    }
    func testLandscapeControlsRemainReachable() throws {
        launch(); enterMonitor()
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in
            self.app.frame.width > self.app.frame.height
        },object:app)
        XCTAssertEqual(XCTWaiter.wait(for:[landscape],timeout:5),.completed)
        XCTAssertTrue(app.buttons["openSettings"].waitForExistence(timeout:5))
        XCTAssertTrue(app.buttons["openSettings"].isHittable)
        assertPrimaryControlsVisible()
        capture("08-monitor-landscape")
        openSettings(); capture("09-more-landscape")
        XCUIDevice.shared.orientation = .portrait
    }
}
