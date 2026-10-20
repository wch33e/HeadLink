import XCTest
import Observation
import SwiftUI
import CoreMotion
import HeadLinkCore
import OpenCineDJI
import OpenCineDJIApple
@testable import HeadLink

private final class ObservationChanges:@unchecked Sendable {
    private let lock=NSLock(); private var count=0
    func note() { lock.lock(); count += 1; lock.unlock() }
    var value:Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// Controlled inputs/transport are test fixtures, not hardware or a production launch mode.
@MainActor final class CalibrationRecoveryTests:XCTestCase {
    private var savedPreferences:[String:Any]=[:]
    private let preferenceKeys=["axes","response","mountMode"]
    override func setUpWithError() throws {
        for key in preferenceKeys { savedPreferences[key]=UserDefaults.standard.object(forKey:key) }
        UserDefaults.standard.set("both",forKey:"axes")
        UserDefaults.standard.set("immediate",forKey:"response")
        UserDefaults.standard.set("fixed",forKey:"mountMode")
    }
    override func tearDownWithError() throws {
        for key in preferenceKeys {
            if let value=savedPreferences[key] { UserDefaults.standard.set(value,forKey:key) }
            else { UserDefaults.standard.removeObject(forKey:key) }
        }
        savedPreferences=[:]
    }
    @MainActor final class Clock {
        var time=100.0
        var attitude=Quaternion.identity
        var sourceErrors=0
        var generation:UInt64=1
        var failed=false { didSet { if failed && !oldValue { sourceErrors += 1 } } }
        var reading:MotionReading { .init(sample:failed ? nil : .init(attitude:attitude,receivedAt:time,sensorTime:time,rotationRate:0,gravity:.init(x:0,y:0,z:-1)),callbackHz:failed ? 0 : 50,failed:failed,sourceErrorCount:sourceErrors,sourceGeneration:generation) }
    }
    @MainActor final class Endpoint:CameraControlEndpoint {
        var isFlowHealthy=true
        var token:UInt64?
        var targets:[Duml.Frame]=[]
        var commands:[Duml.Frame]=[]
        var stops=0
        var onStop:(()->Void)?
        func beginNativeTargets(token:UInt64) { self.token=token }
        func noteNativeTarget(_ frame:Duml.Frame,token:UInt64) -> Bool { guard token == self.token else { return false }; targets.append(frame); return true }
        func endNativeTargets(token:UInt64) { guard self.token == token else { return }; self.token=nil; stops += 1; onStop?() }
        func send(_ frame:Duml.Frame) -> UInt16 { commands.append(frame); return UInt16(commands.count) }
    }
    @MainActor final class FakeMotion:HeadphoneMotionService {
        let clock:Clock
        var available=true
        var active=true
        var deliver=true
        var authorization:CMAuthorizationStatus = .authorized
        var starts=0,stops=0
        init(_ clock:Clock) { self.clock=clock }
        var diagnostic:MotionDeliveryDiagnostic { .init() }
        func start() { guard available,!active else { return }; starts += 1; active=true; clock.generation += 1 }
        func stop() { stops += 1; active=false; clock.generation += 1 }
        func read() -> MotionReading {
            if active,available,deliver { return clock.reading }
            return .init(sample:nil,callbackHz:0,failed:false,sourceErrorCount:clock.sourceErrors,sourceGeneration:clock.generation)
        }
    }
    @MainActor final class Fixture {
        let clock=Clock(),endpoint=Endpoint()
        let camera:PocketCamera
        let motion:FakeMotion
        let model:AppModel
        let parser:DjiAppleDatalink
        init() {
            let clock=self.clock
            motion=FakeMotion(clock)
            camera=PocketCamera(clock:{clock.time},controlEndpoint:endpoint)
            parser=DjiAppleDatalink.loopbackForTesting(port:1)
            camera.link=parser
            model=AppModel(camera:camera,motion:motion)
            camera.selected = .init(id:UUID(),name:"TEST FIXTURE",model:CameraModel.resolve(modelId:0x21,name:"OsmoPocket4-TEST"),modelId:0x21)
            camera.connected=true; camera.connectedAt=clock.time
            camera.status.gimbalModeFamily = .follow
            camera.status.gimbalParams = .init(tiltLock:.unlocked,speed:nil)
            pose(); model.step()
        }
        func frame(set:UInt8,id:UInt8,payload:[UInt8]) -> Duml.Frame {
            .init(sender:0,receiver:0,seq:1,flags:0,cmdSet:set,cmdId:id,payload:payload)
        }
        func pose(at time:Double? = nil,yaw:Double = 0) {
            let receivedAt=time ?? clock.time
            var p=[UInt8](repeating:0,count:50)
            func put(_ value:Int16,_ offset:Int) { let bits=UInt16(bitPattern:value); p[offset]=UInt8(truncatingIfNeeded:bits); p[offset+1]=UInt8(truncatingIfNeeded:bits>>8) }
            put(1800,0); put(Int16((yaw*10).rounded()),4); p[6]=0x80
            let f=frame(set:4,id:5,payload:p)
            parser.acceptAttitudeFramesForTesting([f],receivedAt:receivedAt)
            camera.receive(f,receivedAt:receivedAt)
            camera.parameterAt=clock.time
        }
        func step(_ delta:Double=0.025,withPose:Bool=true) {
            clock.time += delta
            if withPose { pose() }
            model.step()
        }
        func calibrate() {
            model.calibrate()
            for _ in 0..<32 { step() }
        }
        func recordReport(_ recording:Bool) {
            var p=[UInt8](repeating:0,count:13); p[0]=recording ? 0x80 : 0
            camera.receive(frame(set:2,id:0x80,payload:p),receivedAt:clock.time)
        }
    }
    private func observe(_ sheet:CalibrationSheet) -> ObservationChanges {
        let changes=ObservationChanges()
        withObservationTracking { _=sheet.body } onChange: { changes.note() }
        return changes
    }
    func testIgnoredFieldsAloneDoNotPublishReadinessChanges() {
        let f=Fixture(),changes=ObservationChanges()
        withObservationTracking {
            _=f.model.controller.state; _=f.model.canCalibrate; _=f.model.notice
        } onChange: { changes.note() }
        f.step(0.313,withPose:false)
        XCTAssertFalse(f.model.canCalibrate)
        XCTAssertEqual(changes.value,0) // Negative control: the missing revision dependency is real.
    }
    func testOpenSheetObservesStaleThenRestoredInputsWithoutAnotherNotice() {
        let f=Fixture(),sheet=CalibrationSheet(model:f.model)
        f.model.showingCalibration=true
        XCTAssertTrue(f.model.canCalibrate)
        let notice=f.model.notice
        let staleUpdate=observe(sheet)
        f.step(0.313,withPose:false)
        XCTAssertFalse(f.model.canCalibrate)
        XCTAssertTrue(f.model.calibrationBlockers.contains{$0.contains("313 ms")})
        XCTAssertEqual(staleUpdate.value,1)
        XCTAssertEqual(f.model.notice,notice)
        let restoredUpdate=observe(sheet)
        f.step()
        XCTAssertTrue(f.model.canCalibrate)
        XCTAssertTrue(f.model.calibrationBlockers.isEmpty)
        XCTAssertEqual(restoredUpdate.value,1)
        XCTAssertEqual(f.model.notice,notice)
        XCTAssertTrue(f.model.showingCalibration)
        f.model.calibrate()
        XCTAssertEqual(f.model.controller.state,.calibrating)
        let progressUpdate=observe(sheet)
        for _ in 0..<32 { f.step() }
        XCTAssertEqual(progressUpdate.value,1)
        XCTAssertEqual(f.model.controller.state,.calibrated)
        XCTAssertTrue(f.model.controller.hasCalibration)
        XCTAssertFalse(f.model.showingCalibration)
        XCTAssertFalse(f.model.isFollowing)
    }
    func testCalibrationExplicitStartTargetsPauseResumeAndIndependentRecording() {
        let f=Fixture()
        f.calibrate()
        XCTAssertTrue(f.model.canStart)
        XCTAssertTrue(f.endpoint.targets.isEmpty)
        f.model.start()
        XCTAssertTrue(f.model.isFollowing)
        for _ in 0..<32 { f.clock.attitude = .axis(0,0,1,degrees:-1); f.step() }
        XCTAssertFalse(f.endpoint.targets.isEmpty)
        XCTAssertEqual(f.endpoint.targets.last?.cmdSet,4)
        XCTAssertEqual(f.endpoint.targets.last?.cmdId,0x14)
        XCTAssertEqual(f.model.controller.output?.raw.yaw ?? -99,1,accuracy:0.001)
        f.recordReport(false)
        f.camera.toggleRecording()
        XCTAssertEqual(f.camera.recordPending,true)
        XCTAssertEqual(f.camera.actualRecording,false)
        XCTAssertTrue(f.model.isFollowing)
        XCTAssertEqual(f.endpoint.commands.last?.cmdSet,2)
        XCTAssertEqual(f.endpoint.commands.last?.cmdId,2)
        f.recordReport(true)
        XCTAssertEqual(f.camera.actualRecording,true)
        XCTAssertNil(f.camera.recordPending)
        f.model.pause()
        XCTAssertFalse(f.model.isFollowing)
        XCTAssertTrue(f.model.controller.hasCalibration)
        XCTAssertEqual(f.endpoint.stops,1)
        let count=f.endpoint.targets.count
        f.step()
        XCTAssertEqual(f.endpoint.targets.count,count)
        f.model.start()
        XCTAssertTrue(f.model.isFollowing)
    }
    func testOldMainCallbackCannotRefreshOrOverwriteNewerIngressPose() {
        let f=Fixture()
        let old=f.clock.time
        f.clock.time += 0.1; f.pose(yaw:2)
        let newer=f.camera.pose
        f.clock.time += 0.25
        f.camera.receive(f.frame(set:4,id:5,payload:[UInt8](repeating:0,count:50)),receivedAt:old)
        XCTAssertEqual(f.camera.capturePose()?.receivedAt,newer?.receivedAt)
        XCTAssertEqual(f.camera.pose?.angles.yaw,2)
        XCTAssertEqual(f.camera.status.gimbalModeFamily,.follow)
        XCTAssertTrue(f.camera.freshPose != nil)
        f.clock.time += 0.1
        XCTAssertNil(f.camera.freshPose)
        XCTAssertEqual(f.camera.pose?.receivedAt,newer?.receivedAt)
    }
    func testHeadErrorRecoveryCannotRestartWithoutCalibrationAndExplicitStart() {
        let f=Fixture(); f.calibrate(); f.model.start(); f.step()
        f.clock.failed=true; f.step()
        XCTAssertFalse(f.model.isFollowing)
        XCTAssertFalse(f.model.controller.hasCalibration)
        f.clock.failed=false; f.step()
        XCTAssertTrue(f.model.canCalibrate)
        XCTAssertFalse(f.model.canStart)
        XCTAssertTrue(f.camera.connected)
    }
    func testFreshButJumpedHeadReferenceIsStillRejected() {
        let f=Fixture(); f.calibrate(); f.model.start(); f.step()
        f.clock.attitude = .axis(0,0,1,degrees:90); f.step()
        XCTAssertFalse(f.model.isFollowing)
        XCTAssertFalse(f.model.controller.hasCalibration)
        XCTAssertEqual(f.model.controller.invalidation?.reason,.referenceJump)
        XCTAssertTrue(f.camera.connected)
    }
    func testRealCameraStalenessInvalidatesTrackingWithoutDisconnecting() {
        let f=Fixture(); f.calibrate(); f.model.start(); f.step()
        // Keep head samples arriving at their normal rate; only lens telemetry stops.
        for _ in 0..<14 { f.step(withPose:false) }
        XCTAssertFalse(f.model.isFollowing)
        XCTAssertFalse(f.model.controller.hasCalibration)
        XCTAssertTrue(f.camera.connected)
        XCTAssertTrue(f.camera.transportHealthy)
        XCTAssertEqual(f.model.controller.invalidation?.reason,.inputStale)
        f.step()
        XCTAssertTrue(f.model.canCalibrate)
        XCTAssertFalse(f.model.canStart)
    }
    func testEvaluatingPanelsDoesNotStopOrRebuildServices() {
        let f=Fixture(); f.calibrate(); f.model.start(); f.step()
        let camera=f.model.camera,parser=f.camera.link,token=f.endpoint.token
        for _ in 0..<8 {
            _=RootView(model:f.model).body
            _=SettingsView(model:f.model).body
            _=ReadinessForm(model:f.model).body
            f.step()
        }
        XCTAssertTrue(f.model.camera === camera)
        XCTAssertTrue(f.camera.link === parser)
        XCTAssertEqual(f.endpoint.token,token)
        XCTAssertEqual(f.endpoint.stops,0)
        XCTAssertTrue(f.model.isFollowing)
        XCTAssertTrue(f.model.controller.hasCalibration)
    }
    func testCalibrationUsesInputsCapturedAfterSynchronousStopHandoff() {
        let f=Fixture(); f.calibrate(); f.model.start(); f.step()
        f.endpoint.onStop={ f.clock.time += 0.35 }
        defer { f.endpoint.onStop=nil }
        f.model.calibrate()
        XCTAssertNotEqual(f.model.controller.state,.calibrating)
        XCTAssertFalse(f.model.canCalibrate)
        XCTAssertTrue(f.model.calibrationBlockers.contains{$0.contains("镜头姿态已失效")})
    }
    func testTransientErrorBetweenReadsStillInvalidatesTheOldCalibration() {
        let f=Fixture(); f.calibrate(); f.model.start(); f.step()
        f.clock.failed=true; f.clock.failed=false
        f.step()
        XCTAssertFalse(f.model.isFollowing)
        XCTAssertFalse(f.model.controller.hasCalibration)
        XCTAssertTrue(f.model.canCalibrate)
        XCTAssertFalse(f.model.canStart)
        XCTAssertTrue(f.camera.connected)
    }
    func testChangedMotionSessionCannotReuseCalibrationEvenWithFreshSamples() {
        let f=Fixture(); f.calibrate(); f.model.start(); f.step()
        f.clock.generation += 1
        f.step()
        XCTAssertFalse(f.model.isFollowing)
        XCTAssertFalse(f.model.controller.hasCalibration)
        XCTAssertFalse(f.model.canStart)
        XCTAssertTrue(f.camera.connected)
    }
    func testActivateDoesNotSkipLateMotionWhenLoopAlreadyExists() {
        let f=Fixture(); f.motion.active=false; f.motion.available=false
        f.model.activate(); defer { f.model.suspendControl() }
        XCTAssertEqual(f.motion.starts,0)
        f.motion.available=true
        f.model.activate()
        XCTAssertEqual(f.motion.starts,1)
        f.model.activate(); f.step()
        XCTAssertEqual(f.motion.starts,1)
        f.motion.deliver=false
        for _ in 0..<30 { f.clock.time += 1; f.model.step() }
        XCTAssertEqual(f.motion.starts,3)
        f.model.activate()
        XCTAssertEqual(f.motion.starts,3)
    }
    func testBackgroundStopsMotionAndPreservesOnlyOriginalRecoveryIdentity() {
        let f=Fixture(); f.camera.sessionSSID="FIXTURE-SSID"
        f.calibrate(); f.model.start(); f.step()
        f.model.deactivate()
        XCTAssertFalse(f.model.isFollowing)
        XCTAssertFalse(f.model.controller.hasCalibration)
        XCTAssertFalse(f.motion.active)
        XCTAssertFalse(f.camera.connected)
        XCTAssertEqual(f.camera.resumeTarget?.ssid,"FIXTURE-SSID")
        XCTAssertEqual(f.camera.resumeTarget?.sighting.id,f.camera.selected?.id)
        XCTAssertEqual(f.camera.lastDisconnect?.reason,"app_background")
        f.camera.disconnect()
        XCTAssertNil(f.camera.resumeTarget) // User disconnect never silently reconnects.
    }
    func testShortInactiveReturnsFreshWithoutReconnectingOrAutomaticallyMoving() {
        let f=Fixture(); f.calibrate(); f.model.start(); f.step()
        let parser=f.camera.link,starts=f.motion.starts
        f.model.pauseForInactiveScene()
        XCTAssertTrue(f.camera.connected)
        XCTAssertTrue(f.model.controller.hasCalibration)
        f.model.activate(); defer { f.model.suspendControl() }
        XCTAssertTrue(f.camera.link === parser)
        XCTAssertEqual(f.motion.starts,starts)
        XCTAssertFalse(f.model.isFollowing)
        f.step(); f.model.start()
        XCTAssertTrue(f.model.isFollowing)
    }
    func testFreshSamplesRebuildOnlyObservationAfterHeadReferenceLoss() {
        let f=Fixture(); f.calibrate(); f.model.start(); f.step()
        f.clock.attitude = .axis(0,0,1,degrees:90); f.step()
        XCTAssertFalse(f.model.controller.hasCalibration)
        XCTAssertFalse(f.model.isFollowing)
        XCTAssertNotNil(f.model.probe.look)
        XCTAssertFalse(f.model.probe.referenceChanged)
        XCTAssertTrue(f.model.motionLabel.contains("采集正常"))
        XCTAssertEqual(f.model.controller.invalidation?.reason,.referenceJump)
    }
    func testMillisecondChangesKeepTheSameReasonIdentityAndNeverEnableStaleCalibration() {
        let f=Fixture(); f.model.showingCalibration=true
        f.step(0.313,withPose:false)
        let a=f.model.calibrationIssues.first{$0.id == "camera_pose"}
        f.step(0.073,withPose:false)
        let b=f.model.calibrationIssues.first{$0.id == "camera_pose"}
        XCTAssertEqual(a?.id,b?.id); XCTAssertNotEqual(a?.message,b?.message)
        XCTAssertFalse(f.model.canCalibrate)
        f.step(); f.calibrate()
        XCTAssertTrue(f.model.canStart)
    }
    func testRecordingIsIndependentAndTimeoutDoesNotInventActualState() {
        let f=Fixture()
        XCTAssertFalse(f.model.controller.hasCalibration)
        XCTAssertNil(f.camera.actualRecording)
        f.camera.toggleRecording(); XCTAssertTrue(f.endpoint.commands.isEmpty)
        f.recordReport(false); f.camera.toggleRecording()
        XCTAssertEqual(f.camera.recordPending,true)
        f.step(4.1)
        XCTAssertNil(f.camera.recordPending)
        XCTAssertNil(f.camera.actualRecording)
        XCTAssertNotNil(f.camera.recordError)
        let sent=f.endpoint.commands.count
        f.camera.toggleRecording(); XCTAssertEqual(f.endpoint.commands.count,sent)
        f.recordReport(false)
        XCTAssertFalse(f.camera.actualRecording ?? true)
        XCTAssertNil(f.camera.recordError)
        f.camera.toggleRecording(); XCTAssertEqual(f.endpoint.commands.count,sent+1)
        XCTAssertFalse(f.model.controller.hasCalibration)
    }

    func testFutureRecordingReportIsNotTreatedAsFreshTruth() {
        let f=Fixture()
        f.camera.receive(f.frame(set:2,id:0x80,payload:[UInt8](repeating:0,count:13)),receivedAt:f.clock.time+1)
        XCTAssertNil(f.camera.actualRecording)
        f.camera.toggleRecording()
        XCTAssertTrue(f.endpoint.commands.isEmpty)
    }

}
