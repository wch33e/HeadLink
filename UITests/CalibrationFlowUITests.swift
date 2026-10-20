import XCTest

/// Presented SwiftUI sheet + real AppModel/controller using explicitly controlled DEBUG inputs.
/// This does not test camera networking, video, CoreMotion, or physical gimbal motion.
@MainActor final class CalibrationFlowUITests:XCTestCase {
    func testPresentedSheetStaleRecoveryKeepsButtonPositionAndStartsExplicitly() {
        continueAfterFailure=false
        XCUIDevice.shared.orientation = .portrait
        let app=XCUIApplication()
        app.launchArguments=["-HeadLinkControlledInputs","-onboarded","YES","-axes","both","-response","immediate","-mountMode","fixed"]
        app.launch()
        XCTAssertTrue(app.buttons["enterMonitor"].waitForExistence(timeout:15))
        app.buttons["enterMonitor"].tap()
        let record=app.buttons["recordToggle"]
        XCTAssertTrue(record.waitForExistence(timeout:5)); XCTAssertTrue(record.isEnabled)
        record.tap()
        let recorded=XCTNSPredicateExpectation(predicate:NSPredicate(format:"label CONTAINS %@","停止录像"),object:record)
        XCTAssertEqual(XCTWaiter.wait(for:[recorded],timeout:5),.completed)
        record.tap()
        app.buttons["calibrate"].tap()
        let begin=app.buttons["beginCalibration"]
        XCTAssertTrue(begin.waitForExistence(timeout:5)); XCTAssertTrue(begin.isEnabled)
        let initialFrame=begin.frame
        let freeze=app.buttons["fixtureStale"]
        if !freeze.isHittable { app.swipeDown() }
        XCTAssertTrue(freeze.isHittable); freeze.tap()
        let stale=XCTNSPredicateExpectation(predicate:NSPredicate(format:"enabled == NO"),object:begin)
        XCTAssertEqual(XCTWaiter.wait(for:[stale],timeout:5),.completed)
        XCTAssertTrue(app.staticTexts["calibrationReason_camera_pose"].exists)
        XCTAssertEqual(begin.frame.minY,initialFrame.minY,accuracy:1)
        app.buttons["fixtureFresh"].tap()
        let fresh=XCTNSPredicateExpectation(predicate:NSPredicate(format:"enabled == YES"),object:begin)
        XCTAssertEqual(XCTWaiter.wait(for:[fresh],timeout:5),.completed)
        XCTAssertEqual(begin.frame.minY,initialFrame.minY,accuracy:1)
        let attachment=XCTAttachment(screenshot:XCUIScreen.main.screenshot())
        attachment.name="calibration-presented-recovered-controlled-inputs"; attachment.lifetime = .keepAlways; add(attachment)
        begin.tap()
        let closed=XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == NO"),object:begin)
        XCTAssertEqual(XCTWaiter.wait(for:[closed],timeout:8),.completed)
        XCTAssertTrue(app.buttons["followToggle"].isEnabled)
        XCTAssertFalse(app.buttons["alwaysPause"].exists)
        app.buttons["followToggle"].tap()
        XCTAssertTrue(app.buttons["alwaysPause"].waitForExistence(timeout:5))
        app.buttons["alwaysPause"].tap()
        XCTAssertTrue(app.buttons["followToggle"].waitForExistence(timeout:5))
        XCTAssertTrue(app.buttons["recordToggle"].isEnabled)
        app.terminate()
    }
}
