#if DEBUG
import SwiftUI
import CoreMotion
import HeadLinkCore
import OpenCineDJI
import OpenCineDJIApple

/// Explicit XCUITest-only controlled input. Not hardware evidence and excluded from Release.
@MainActor final class DebugFlowFixture:HeadphoneMotionService,CameraControlEndpoint {
    static var current:DebugFlowFixture?
    var time=100.0
    var poseEnabled=true
    var active=true
    var available=true
    var authorization:CMAuthorizationStatus = .authorized
    var diagnostic:MotionDeliveryDiagnostic { .init() }
    var isFlowHealthy:Bool { true }
    var recording=false
    var token:UInt64?
    var camera:PocketCamera!
    var parser:DjiAppleDatalink!
    func start() { active=true }
    func stop() { active=false }
    func beginNativeTargets(token:UInt64) { self.token=token }
    func noteNativeTarget(_ frame:Duml.Frame,token:UInt64) -> Bool { self.token == token }
    func endNativeTargets(token:UInt64) { self.token=nil }
    func send(_ frame:Duml.Frame) -> UInt16 {
        if frame.cmdSet == 2,frame.cmdId == 2 { recording=frame.payload.first == 1 }
        return 1
    }
    func read() -> MotionReading {
        // Virtual time is controlled so this test measures presentation/state, not simulator scheduling.
        time += 0.0125
        camera.videoCheckAt=time // No video source is provided or claimed by this fixture.
        if poseEnabled {
            var bytes=[UInt8](repeating:0,count:50); bytes[0]=0x08; bytes[1]=0x07; bytes[6]=0x80
            let frame=Duml.Frame(sender:0,receiver:0,seq:1,flags:0,cmdSet:4,cmdId:5,payload:bytes)
            parser.acceptAttitudeFramesForTesting([frame],receivedAt:time)
            camera.receive(frame,receivedAt:time); camera.parameterAt=time
        }
        var report=[UInt8](repeating:0,count:13); report[0]=recording ? 0x80 : 0
        camera.receive(.init(sender:0,receiver:0,seq:2,flags:0,cmdSet:2,cmdId:0x80,payload:report),receivedAt:time)
        return .init(sample:active ? .init(attitude:.identity,receivedAt:time,sensorTime:time,rotationRate:0,gravity:.init(x:0,y:0,z:-1)) : nil,
            callbackHz:active ? 50 : 0,failed:false,sourceErrorCount:0,sourceGeneration:1)
    }
    static func makeModel() -> AppModel {
        let fixture=DebugFlowFixture(); current=fixture
        let camera=PocketCamera(clock:{fixture.time},controlEndpoint:fixture)
        fixture.camera=camera; fixture.parser=DjiAppleDatalink.loopbackForTesting(port:1); camera.link=fixture.parser
        camera.selected = .init(id:UUID(),name:"CONTROLLED TEST INPUT",model:CameraModel.resolve(modelId:0x21,name:"OsmoPocket4-TEST"),modelId:0x21)
        camera.connected=true; camera.connectedAt=fixture.time
        camera.status.gimbalModeFamily = .follow; camera.status.gimbalParams = .init(tiltLock:.unlocked,speed:nil)
        camera.message="受控输入测试；没有硬件或视频验证"
        let model=AppModel(camera:camera,motion:fixture)
        model.step()
        return model
    }
}
struct DebugCalibrationInputControls:View {
    var body:some View {
        if let fixture=DebugFlowFixture.current {
            VStack {
                Text("CONTROLLED INPUT TEST — NO HARDWARE").font(.caption)
                HStack {
                    Button("冻结镜头输入") { fixture.poseEnabled=false }.accessibilityIdentifier("fixtureStale")
                    Button("恢复镜头输入") { fixture.poseEnabled=true }.accessibilityIdentifier("fixtureFresh")
                }.buttonStyle(.bordered).frame(minHeight:44)
            }
        }
    }
}
#endif
