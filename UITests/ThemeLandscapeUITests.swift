import XCTest
import UIKit

/// Real SwiftUI presentations and real simulator system traits, with explicit controlled motion/transport.
/// No hardware, live video or physical pointing claim is made by these tests.
@MainActor final class ThemeLandscapeUITests:XCTestCase {
    private var app:XCUIApplication!
    private func launch(reset:Bool=true) {
        continueAfterFailure=false;XCUIDevice.shared.orientation = .portrait
        app=XCUIApplication()
        app.launchArguments=["-HeadLinkControlledInputs","-onboarded","YES","-axes","both","-response","immediate","-mountMode","fixed"]
        if reset { app.launchArguments.append("-HeadLinkResetPresentation") }
        app.launch()
        XCTAssertTrue(app.buttons["enterMonitor"].waitForExistence(timeout:15))
        app.buttons["enterMonitor"].tap()
    }
    private func wait(_ element:XCUIElement,_ predicate:String,_ value:Any?=nil,timeout:TimeInterval=10) {
        let p=value.map{NSPredicate(format:predicate,argumentArray:[$0])} ?? NSPredicate(format:predicate)
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:p,object:element)],timeout:timeout),.completed)
    }
    private func startAndRecord() {
        app.buttons["calibrate"].tap()
        let begin=app.buttons["beginCalibration"]
        XCTAssertTrue(begin.waitForExistence(timeout:5));begin.tap();wait(begin,"exists == NO")
        app.buttons["followToggle"].tap()
        XCTAssertTrue(app.buttons["alwaysPause"].waitForExistence(timeout:5))
        app.buttons["recordToggle"].tap()
        wait(app.buttons["recordToggle"],"label CONTAINS %@","停止录像")
    }
    private func openDetails(expand:Bool=true) {
        app.buttons["openShootingDetails"].tap()
        XCTAssertTrue(app.buttons["closeShootingDetails"].waitForExistence(timeout:5))
        if expand,app.buttons["toggleDetails"].label == "展开详情" { app.buttons["toggleDetails"].tap() }
        XCTAssertTrue(app.staticTexts["fixturePipeline"].waitForExistence(timeout:5))
    }
    private func pipeline() -> String { app.staticTexts["fixturePipeline"].label }
    private func assertFollowingAndRecording() {
        XCTAssertTrue(pipeline().contains("state=following"),pipeline())
        XCTAssertTrue(pipeline().contains("has=true"),pipeline())
        XCTAssertTrue(pipeline().contains("record=true"),pipeline())
        XCTAssertTrue(app.buttons["detailsPause"].isHittable)
    }
    private func capture(_ name:String) {
        let a=XCTAttachment(screenshot:XCUIScreen.main.screenshot());a.name=name;a.lifetime = .keepAlways;add(a)
    }
    private func chooseAppearance(_ title:String) {
        app.buttons["openSettings"].tap()
        let picker=app.buttons["appearanceSetting"]
        XCTAssertTrue(picker.waitForExistence(timeout:5));picker.tap();app.buttons[title].tap()
        app.buttons["closeSettings"].tap()
    }
    func testSystemThemeChangesInOpenSheetManualOverrideAndPersistence() {
        launch();chooseAppearance("跟随系统");startAndRecord();openDetails()
        assertFollowingAndRecording();let state=pipeline()
        app.buttons["fixtureSystemLight"].tap();wait(app.staticTexts["fixtureHostTheme"],"label == %@","host_light",timeout:20);wait(app.staticTexts["fixtureTheme"],"label == %@","theme_light",timeout:20)
        capture("theme-system-light-open-details")
        app.buttons["fixtureSystemDark"].tap();wait(app.staticTexts["fixtureHostTheme"],"label == %@","host_dark",timeout:20);wait(app.staticTexts["fixtureTheme"],"label == %@","theme_dark",timeout:20)
        capture("theme-system-dark-open-details")
        XCTAssertEqual(pipeline(),state)
        app.buttons["fixtureSystemLight"].tap();wait(app.staticTexts["fixtureHostTheme"],"label == %@","host_light",timeout:20);wait(app.staticTexts["fixtureTheme"],"label == %@","theme_light",timeout:20)
        app.buttons["closeShootingDetails"].tap()
        chooseAppearance("深色");openDetails()
        wait(app.staticTexts["fixtureTheme"],"label == %@","theme_dark")
        XCTAssertEqual(pipeline(),state)
        app.buttons["closeShootingDetails"].tap()
        app.terminate();launch(reset:false);openDetails()
        wait(app.staticTexts["fixtureTheme"],"label == %@","theme_dark")
        app.buttons["closeShootingDetails"].tap()
        chooseAppearance("跟随系统");openDetails()
        wait(app.staticTexts["fixtureTheme"],"label == %@","theme_light")
        app.buttons["closeShootingDetails"].tap()
        chooseAppearance("浅色");openDetails()
        app.buttons["fixtureSystemDark"].tap()
        wait(app.staticTexts["fixtureHostTheme"],"label == %@","host_dark",timeout:20)
        wait(app.staticTexts["fixtureTheme"],"label == %@","theme_light")
        app.buttons["fixtureSystemLight"].tap()
        wait(app.staticTexts["fixtureHostTheme"],"label == %@","host_light",timeout:20)
        app.terminate()
    }
    private func assertLayout(leftHanded:Bool) {
        let preview=app.descendants(matching:.any).matching(identifier:"previewRegion").firstMatch
        XCTAssertTrue(preview.exists);let rect=preview.frame
        XCTAssertGreaterThan(rect.width,80);XCTAssertGreaterThan(rect.height,60)
        var frames:[CGRect]=[]
        for id in ["calibrate","alwaysPause","recordToggle","openSettings"] {
            let button=app.buttons[id];XCTAssertTrue(button.isHittable,id)
            let b=button.frame;frames.append(b)
            XCTAssertGreaterThanOrEqual(b.width,44,id);XCTAssertGreaterThanOrEqual(b.height,44,id)
            XCTAssertGreaterThanOrEqual(b.minX,app.frame.minX,id);XCTAssertLessThanOrEqual(b.maxX,app.frame.maxX,id)
            XCTAssertGreaterThanOrEqual(b.minY,app.frame.minY,id);XCTAssertLessThanOrEqual(b.maxY,app.frame.maxY,id)
            XCTAssertFalse(b.intersects(rect),id+" overlaps reserved preview")
        }
        for i in frames.indices { for j in frames.indices where i < j { XCTAssertFalse(frames[i].intersects(frames[j])) } }
        if app.frame.width > app.frame.height {
            XCTAssertEqual(app.buttons["alwaysPause"].frame.midX < rect.midX,leftHanded)
        }
    }
    func testBothLandscapeDirectionsAndLeftHandedLayoutPreserveActivePipeline() {
        launch();startAndRecord();openDetails();assertFollowingAndRecording();let state=pipeline()
        app.buttons["closeShootingDetails"].tap()
        for hand in [false,true] {
            if hand {
                app.buttons["openSettings"].tap()
                XCTAssertTrue(app.buttons["closeSettings"].waitForExistence(timeout:5))
                let display=app.buttons["openDisplaySettings"]
                for _ in 0..<6 {
                    if display.exists && display.isHittable { break }
                    app.swipeUp()
                }
                XCTAssertTrue(display.isHittable);display.tap()
                let row=app.switches["leftHandedSetting"]
                if row.value as? String != "1" { row.coordinate(withNormalizedOffset:.init(dx:0.9,dy:0.5)).tap() }
                app.navigationBars.buttons.element(boundBy:0).tap();app.buttons["closeSettings"].tap()
            }
            for orientation:UIDeviceOrientation in [.landscapeLeft,.landscapeRight,.portrait] {
                XCUIDevice.shared.orientation=orientation
                let rotated=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in
                    orientation == .portrait ? self.app.frame.width < self.app.frame.height : self.app.frame.width > self.app.frame.height
                },object:app)
                XCTAssertEqual(XCTWaiter.wait(for:[rotated],timeout:5),.completed)
                assertLayout(leftHanded:hand)
                capture("layout-\(orientation.rawValue)-left-\(hand)")
                openDetails();assertFollowingAndRecording();XCTAssertEqual(pipeline(),state)
                app.buttons["closeShootingDetails"].tap()
            }
        }
        app.terminate()
    }
    func testDetailsClickDragAndRangeSummaryDoNotRestartOrMoveCalibration() {
        launch();startAndRecord();openDetails();assertFollowingAndRecording();let state=pipeline()
        app.buttons["fixtureRange"].tap()
        app.buttons["closeShootingDetails"].tap()
        wait(app.staticTexts["trackingState"],"label == %@","目标已限位")
        let rect=app.buttons["alwaysPause"].frame
        openDetails();assertFollowingAndRecording();XCTAssertEqual(pipeline(),state)
        app.buttons["fixtureOrigin"].tap()
        app.buttons["closeShootingDetails"].tap()
        wait(app.staticTexts["trackingState"],"label == %@","跟随中")
        XCTAssertEqual(app.buttons["alwaysPause"].frame,rect)
        openDetails();XCTAssertEqual(pipeline(),state)
        let grabber=app.buttons.matching(NSPredicate(format:"label CONTAINS %@ OR label CONTAINS %@","表单控制柄","Grabber")).firstMatch
        XCTAssertTrue(grabber.exists)
        let start=grabber.coordinate(withNormalizedOffset:.init(dx:0.5,dy:0.5))
        let end=app.coordinate(withNormalizedOffset:.init(dx:0.5,dy:0.9))
        start.press(forDuration:0.05,thenDragTo:end)
        wait(app.staticTexts["fixtureDetent"],"exists == NO OR label != %@","expanded")
        if app.buttons["closeShootingDetails"].exists { app.buttons["closeShootingDetails"].tap() }
        openDetails();assertFollowingAndRecording();XCTAssertEqual(pipeline(),state)
        app.buttons["toggleDetails"].tap() // Click collapse remains available without a gesture.
        XCTAssertTrue(app.buttons["closeShootingDetails"].exists)
        app.buttons["closeShootingDetails"].tap();app.terminate()
    }
}
