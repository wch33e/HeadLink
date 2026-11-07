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
    var headYaw=0.0
    var headDemandYaw=0.0
    var actual=Angles.zero
    var nativePitch=180.0
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
    func noteNativeTarget(_ frame:Duml.Frame,token:UInt64,deadline:Double?) -> Bool {
        guard self.token == token else { return false }
        actual.yaw=Double(GimbalStick.i16LE(frame.payload,at:0) ?? 0)/10
        nativePitch=Double(GimbalStick.i16LE(frame.payload,at:4) ?? 0)/10
        actual.pitch=Orientation.wrap(180-nativePitch)
        return true
    }
    func endNativeTargets(token:UInt64) { self.token=nil }
    func send(_ frame:Duml.Frame) -> UInt16 {
        if frame.cmdSet == 2,frame.cmdId == 2 { recording=frame.payload.first == 1 }
        return 1
    }
    func read() -> MotionReading {
        // Virtual time is controlled so this test measures presentation/state, not simulator scheduling.
        time += 0.0125
        headYaw += max(-0.5,min(0.5,headDemandYaw-headYaw))
        camera.videoCheckAt=time // No video source is provided or claimed by this fixture.
        if poseEnabled {
            var bytes=[UInt8](repeating:0,count:50); bytes[6]=0x80
            func put(_ value:Double,_ offset:Int) {
                let bits=UInt16(bitPattern:Int16((value*10).rounded()))
                bytes[offset]=UInt8(truncatingIfNeeded:bits); bytes[offset+1]=UInt8(truncatingIfNeeded:bits>>8)
            }
            put(nativePitch,0); put(actual.yaw,4); put(-actual.pitch,20)
            let frame=Duml.Frame(sender:0,receiver:0,seq:1,flags:0,cmdSet:4,cmdId:5,payload:bytes)
            parser.acceptAttitudeFramesForTesting([frame],receivedAt:time)
            camera.receive(frame,receivedAt:time); camera.parameterAt=time
        }
        var report=[UInt8](repeating:0,count:13); report[0]=recording ? 0x80 : 0
        camera.receive(.init(sender:0,receiver:0,seq:2,flags:0,cmdSet:2,cmdId:0x80,payload:report),receivedAt:time)
        return .init(sample:active ? .init(attitude:.axis(0,0,1,degrees:-headYaw),receivedAt:time,sensorTime:time,rotationRate:0,gravity:.init(x:0,y:0,z:-1)) : nil,
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
struct DebugThemeLabel:View {
    @Environment(\.colorScheme) private var scheme
    var body:some View {
        if DebugFlowFixture.current != nil {
            Text(scheme == .dark ? "theme_dark" : "theme_light").accessibilityIdentifier("fixtureTheme").font(.caption)
        }
    }
}
struct DebugPresentationProbe:View {
    @Bindable var model:AppModel
    var body:some View {
        let _=model.telemetryRevision
        if let fixture=DebugFlowFixture.current {
            VStack(alignment:.leading,spacing:8) {
                DebugThemeLabel()
                Text("host_"+hostTheme).accessibilityIdentifier("fixtureHostTheme").font(.caption)
                Text("state=\(model.controller.state.rawValue);cal=\(model.controller.calibrationID);has=\(model.controller.hasCalibration);epoch=\(model.camera.connectionEpoch);record=\(model.camera.actualRecording.map{$0 ? "true" : "false"} ?? "unknown");decoder=\(ObjectIdentifier(model.camera.decoder))")
                    .font(.caption).accessibilityIdentifier("fixturePipeline")
                Button("测试系统深色") { requestTheme("dark") }.accessibilityIdentifier("fixtureSystemDark")
                Button("测试系统浅色") { requestTheme("light") }.accessibilityIdentifier("fixtureSystemLight")
                Button("测试超限输入") { fixture.headDemandYaw = -60 }.accessibilityIdentifier("fixtureRange")
                Button("测试回到原点") { fixture.headDemandYaw=0 }.accessibilityIdentifier("fixtureOrigin")
            }
        }
    }
    private var hostTheme:String {
        guard let dir=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first,
            let data=try? Data(contentsOf:dir.appendingPathComponent("HeadLinkThemeAck.json")),
            let value=try? JSONSerialization.jsonObject(with:data) as? [String:String] else { return "unknown" }
        return value["mode"] ?? "unknown"
    }
    private func requestTheme(_ mode:String) {
        guard let dir=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first else { return }
        let data=try? JSONSerialization.data(withJSONObject:["mode":mode,"nonce":UUID().uuidString])
        try? data?.write(to:dir.appendingPathComponent("HeadLinkThemeRequest.json"),options:.atomic)
    }
}
#endif
