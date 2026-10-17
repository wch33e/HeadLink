import Foundation
import Observation
import OpenCineDJI
import OpenCineDJIApple
import OpenCineMotion
import OpenCineApple
import HeadLinkCore

/// Production adapter. Wire values and connection sequencing come only from pinned OpenCine.
@MainActor @Observable final class PocketCamera {
    var sightings: [DjiAppleSighting] = []
    var message = "未连接"
    var connected = false
    var selected: DjiAppleSighting?
    @ObservationIgnored var pose: CameraPose?
    @ObservationIgnored var lastAttitudeLength:Int?
    @ObservationIgnored var attitudeFrames=0
    @ObservationIgnored var poseFrames=0
    @ObservationIgnored var parameterAt:Double?
    @ObservationIgnored var lastSubmittedAngles:Angles?
    @ObservationIgnored var lastSubmittedNativePitch:Double?
    @ObservationIgnored var targetSubmissions=0
    @ObservationIgnored var lastCommandIssue:String?
    @ObservationIgnored var lastStopAttemptAt:Double?

    @ObservationIgnored var status = CameraStatus()
    @ObservationIgnored var statusAt: Double?
    @ObservationIgnored var recordingAt: Double?
    var recordPending: Bool?
    var recordDeadline: Double?
    var recordError: String?
    var wifiRequest: DjiAppleConnectionTransport.AccessPointJoin?
    var decoder = MonitorLiveVideoRuntime()
    @ObservationIgnored var lastPresentedAt: Double?
    @ObservationIgnored var lastDisconnect:CameraDisconnect?
    @ObservationIgnored var connectionEpoch:UInt64=0
    @ObservationIgnored var connectedAt:Double?
    @ObservationIgnored var lastControlFrameAt:Double?
    @ObservationIgnored var unhealthySince:Double?
    @ObservationIgnored var sessionHealth=CameraSessionHealthPolicy()
    @ObservationIgnored let network=CameraNetworkObserver()
    @ObservationIgnored var attitudeObservation:CameraAttitudeObservation?
    @ObservationIgnored var lastHealthClassification="not_observed"
    @ObservationIgnored var onSessionEvent:((String,String)->Void)?
    @ObservationIgnored var videoPolicy=VideoRecoveryPolicy()
    @ObservationIgnored var videoRecoveryTask:Task<Void,Never>?
    @ObservationIgnored var videoTimeoutTask:Task<Void,Never>?
    @ObservationIgnored var videoCheckAt=0.0
    @ObservationIgnored var videoHistoryAt=0.0
    @ObservationIgnored var videoHistory:[VideoDiagnostic]=[]
    @ObservationIgnored var videoDiagnostic:VideoDiagnostic?
    @ObservationIgnored var lastCompleteAccessUnitAt:Double?
    @ObservationIgnored var lastAcceptedSampleAt:Double?
    @ObservationIgnored var lastCameraSetAt:Double?
    @ObservationIgnored var onVideoEvent:((String,String)->Void)?
    @ObservationIgnored var onControlTransportReset:(()->Void)?
    var videoMessage="等待视频"

    @ObservationIgnored var onDisconnected: (() -> Void)?
    @ObservationIgnored var link: DjiAppleDatalink?
    @ObservationIgnored private var scanTask: Task<Void,Never>?
    @ObservationIgnored private var wifiContinue = false
    @ObservationIgnored private var targetToken: UInt64?
    @ObservationIgnored private var tokenCounter: UInt64 = 0
    @ObservationIgnored private var connectRun: DjiAppleConnectionRun?
    @ObservationIgnored private lazy var bluetooth = DjiAppleBluetoothLink(host: .init(
        logSubsystem:"org.headlink.app", bluetoothDenied:"请在设置中允许蓝牙权限",bluetoothOff:"请开启蓝牙",bluetoothNotReady:"蓝牙尚未就绪"))
    @ObservationIgnored private lazy var exchange = DjiAppleControlExchange(
        endpoint:.init(writeBLE:{ [weak self] in self?.bluetooth.send($0) },writeDatalink:{ [weak self] frame in
            guard let link=self?.link else { return .skipped }; return .queued(link.send(frame))
        }),context:{ [weak self] in .init(canTransmit:self?.connected == true,reported:self?.status) })
    @ObservationIgnored private lazy var heartbeat = DjiAppleSessionHeartbeat(
        endpoint:.init(writeBLE:{ [weak self] in self?.bluetooth.send($0) },registerDatalink:{ [weak self] in self?.link?.reRegister() },transport:{ [weak self] in
            .init(lastVideoAt:self?.link?.lastVideoPacketAt?.timeIntervalSinceReferenceDate,rebuilding:self?.link?.isRebuilding ?? false)
        }),
        context:{ [weak self] in .init(live:self?.connected == true,ownedConnection:true,
            pathReady:DjiAppleWiFiJoiner.isCameraPathReady(),sceneActive:true,holdsMonitor:true) },event:{ [weak self] event in
            if event == .cameraPathLost { self?.disconnect(reason:"camera_path_lost") }
        })
    var now: Double { ProcessInfo.processInfo.systemUptime }
    var freshPose: CameraPose? { guard let pose,pose.fresh(at:now) else { return nil }; return pose }
    var actualRecording: Bool? {
        guard connected,status.recordingReported,let t=recordingAt,now-t <= 2 else { return nil }
        return status.isRecording
    }
    var previewLive: Bool { videoSample().live }
    var transportHealthy: Bool { connected && link?.isFlowHealthy == true }
    // Counts actual UDP writes, not UI timer ticks or accepted mailbox submissions.
    var nativeWrites: Int { link?.headLinkNativeWriteCount ?? 0 }

    func scan() {
        disconnect(reason:"scan_started"); sightings=[]; message="搜索相机…"
        scanTask=Task { [weak self] in
            guard let self else { return }
            guard await bluetooth.waitUntilPoweredOn() else { message=bluetooth.unavailableReason; return }
            for await sighting in bluetooth.scan() {
                guard !Task.isCancelled else { break }
                if sighting.model.hasGimbal, !sightings.contains(where:{$0.id == sighting.id}) { sightings.append(sighting) }
            }
        }
    }
    func connect(_ sighting: DjiAppleSighting) {
        disconnect(reason:"replace_connection"); selected=sighting; message="连接中…"
        network.start(); sessionHealth = .init(); attitudeObservation=nil
        decoder=MonitorLiveVideoRuntime(); decoder.onPresentedFrame={ [weak self] in self?.lastPresentedAt=self?.now }
        var transport=DjiAppleConnectionTransport(bluetooth:bluetooth)
        // Replace only the OS Wi-Fi action; retain upstream pairing, identity verification and registration.
        transport.network.joinAccessPoint={ [weak self] request in
            guard let self else { throw CancellationError() }
            wifiRequest=request; wifiContinue=false; message="请手动加入相机 Wi-Fi"
            defer { wifiRequest=nil }
            let deadline=ContinuousClock.now.advanced(by:.seconds(180))
            while !wifiContinue {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw DjiAppleConnectionRun.Failure.timeout }
                try await Task.sleep(for:.milliseconds(150))
            }
            guard DjiAppleWiFiJoiner.isCameraPathReady() else { throw DjiAppleConnectionRun.Failure.hostWiFi("manual path unavailable") }
        }
        transport.network.currentSSID={ nil }
        transport.network.leave={ _ in }
        connectRun=DjiAppleConnectionRun(transport:transport,exchange:exchange,heartbeat:heartbeat,
            credentials:.init(savedPath:{ _,_ in .init() },resolveWiFi:{ _ in .init() },joinPolicy:{ _,_,_ in .init() },
                validateSSID:{ _,_,_ in },persist:{ _,_,_ in },rejectCached:{ _,_ in }),
            native:.init(observe:{ [weak self] in .init(ownsConnection:true,endpoint:self?.link) },prepare:{ _,_,_ in },
                attach:{ [weak self] endpoint,_,_ in
                    self?.link?.close(); self?.link=endpoint as? DjiAppleDatalink
                    self?.bindLink()
                },registered:{ [weak self] _,_,_ in
                    self?.connected=true; self?.beginVideoSession(); self?.message="已连接（兼容性待真机验证）"
                    self?.link?.startLiveView()
                }), event:{ [weak self] event in
                    guard let self else { return }
                    switch event {
                    case .stage(let stage,_): message=Self.stageLabel(stage)
                    case .finished(.failure(_),_):
                        disconnect(reason:"connection_setup_failed"); message="连接失败：请检查相机确认、Wi-Fi 和本地网络权限后重试"
                    default: break
                    }
                })
        connectRun?.replace(target:.init(id:sighting.id.uuidString,name:sighting.name,model:sighting.model,modelId:sighting.modelId),route:.cameraAccessPoint)
    }
    private static func stageLabel(_ stage: DJIConnectionStage) -> String {
        // Descriptions are intentionally independent of the protocol's internal progress text.
        switch stage {
        case .connectingBluetooth: return "正在连接蓝牙"
        case .pairing, .awaitingApproval: return "请在相机上确认配对"
        case .readingWiFi: return "正在读取相机连接信息"
        case .joiningWiFi: return "等待手动加入 Wi-Fi"
        case .openingDatalink: return "正在验证相机通信"
        default: return "正在建立连接"
        }
    }
    private func bindLink() {
        guard let link else { return }
        link.onStatusFrame={ [weak self] frame in self?.receive(frame) }
        let source=decoder.sourceToken
        link.onAccessUnit={ [weak self] bytes in
            guard let self,self.connected else { return }
            lastCompleteAccessUnitAt=now
            if decoder.decode(accessUnit:bytes,source:source) { lastAcceptedSampleAt=now }
        }
        link.onVideoDiscontinuity={ [weak self] in self?.decoder.noteCompressedDiscontinuity() }
    }
    private func receive(_ frame: Duml.Frame) {
        lastControlFrameAt=now
        if frame.cmdSet == 4,frame.cmdId == 5,frame.payload.count == 50 {
            let q=WorldLevel.attitude(frame.payload)
            attitudeObservation = .init(receivedAt:now,payloadHex:frame.payload.map{String(format:"%02x",$0)}.joined(),
                quaternionWorldToCamera:q.map{.init(w:$0.w,x:$0.x,y:$0.y,z:$0.z)},
                interpretation:"upstream_lens_world_to_camera; neck_mount_axes_and_heading_continuity_unqualified; not_body_attitude; receipt_time_only")
        }
        exchange.receive(frame)
        if frame.cmdSet == 4,frame.cmdId == 5 { lastAttitudeLength=frame.payload.count; attitudeFrames += 1 }
        if CameraStatusDecoder.apply(frame,to:&status,model:selected?.model) {
            statusAt=now
            if frame.cmdSet == 4,frame.cmdId == 0x50 { parameterAt=now }
        }
        if frame.cmdSet == 2,frame.cmdId == 0x80,frame.payload.count >= 13 {
            recordingAt=now
            if recordPending == status.isRecording {
                onSessionEvent?("record_confirmed",status.isRecording ? "recording_true_from_camera" : "recording_false_from_camera")
                recordPending=nil; recordDeadline=nil
            }
        }
        if frame.cmdSet == 4,frame.cmdId == 5,
           let yaw=GimbalStick.yawTenthDeg(frame.payload),let pitch=GimbalStick.pitchTenthDeg(frame.payload),
           let native=GimbalStick.nativePitchTenthDeg(frame.payload) {
            poseFrames += 1
            let unwrapped=GimbalWaypoint.unwrapYaw(Double(yaw)/10)
            pose = .init(angles:.init(yaw:unwrapped,pitch:Double(pitch)/10),nativePitch:Double(native)/10,receivedAt:now)
        }
    }
    func confirmWiFi() { wifiContinue=true }
    func startTargets() -> Bool {
        guard transportHealthy else { lastCommandIssue="控制传输未就绪，未建立目标队列"; return false }
        guard freshPose != nil else { lastCommandIssue="镜头姿态缺失或超过300ms，未建立目标队列"; return false }
        lastCommandIssue=nil
        stopTargets(); tokenCounter &+= 1; targetToken=tokenCounter; link?.beginNativeTargets(token:tokenCounter); return true
    }
    func submit(_ output: TrackingOutput) -> Bool {
        submit(angles:output.command,nativePitch:output.nativePitch)
    }
    func submit(angles:Angles,nativePitch:Double) -> Bool {
        guard transportHealthy else { lastCommandIssue="相机传输不可用"; return false }
        guard let live=freshPose else { lastCommandIssue="镜头姿态已过期或布局不受支持"; return false }
        guard abs((angles.yaw*10).rounded()/10-live.angles.yaw) < 180 else {
            lastCommandIssue="目标与实际yaw相隔至少180°，直接指令可能穿越不可达扇区，已拒绝；请暂停后明确重新对齐"; return false
        }
        guard let token=targetToken else { lastCommandIssue="目标流未启动或已经暂停"; return false }
        guard let frame=Commands.gimbalTimedTarget(yawDeg:angles.yaw,nativePitchDeg:nativePitch,duration:0.1) else {
            lastCommandIssue="角度被已核实命令编码器拒绝"; return false
        }
        guard link?.noteNativeTarget(frame,token:token) == true else {
            lastCommandIssue="目标队列拒绝：可能被底层新鲜度或可达路径检查停止"; return false
        }
        lastSubmittedAngles=angles; lastSubmittedNativePitch=nativePitch; targetSubmissions += 1; lastCommandIssue=nil
        return true
    }
    func refreshControlInfo() {
        guard connected else { return }
        _=link?.sendUntracked(Commands.gimbalParamsGet())
    }
    var followModeBlock:String? {
        if let family=status.gimbalModeFamily, family != .follow { return "机身当前不是跟随模式，请在相机下拉菜单选择跟随" }
        if let parameterAt,now-parameterAt < 3,status.gimbalParams?.tiltLock == .locked {
            return "相机报告俯仰已锁定，请在机身改为跟随模式"
        }
        return nil
    }
    var controlModeReadiness:String? {
        if let reason=followModeBlock { return reason }
        guard status.gimbalModeFamily == .follow,let pose,pose.fresh(at:now) else { return "等待真实Follow模式与新鲜姿态回报" }
        guard let parameterAt,now-parameterAt < 3,let params=status.gimbalParams else { return "等待新鲜云台参数回报（每2秒自动查询）" }
        guard params.tiltLock == .unlocked else { return "俯仰锁定，需在机身选择Follow模式" }
        return nil
    }
    var modeSummary:String {
        guard let family=status.gimbalModeFamily,let pose,pose.fresh(at:now) else { return "不可用；请在机身下拉菜单核对" }
        switch family {
        case .directionLock:return "方向锁定（姿态推送）"
        case .fpv:return "FPV（姿态推送）"
        case .follow:
            guard let parameterAt,now-parameterAt < 3,let params=status.gimbalParams else { return "跟随族；俯仰锁定参数未收到" }
            return params.tiltLock == .unlocked ? "跟随／俯仰未锁定（真实回报）" : "俯仰锁定（真实回报）"
        }
    }
    func stopTargets() {
        guard let token=targetToken else { return }; targetToken=nil
        lastStopAttemptAt=now
        link?.endNativeTargets(token:token)
        // This command is notify-only; no claim that a stopped pose was confirmed.
    }
    func toggleRecording() {
        guard connected,recordPending == nil,let current=actualRecording else { return }
        onSessionEvent?("record_requested",current ? "stop; awaiting_camera_report" : "start; awaiting_camera_report")
        lastCameraSetAt=now
        recordError=nil; recordPending = !current; recordDeadline=now+4
        _=link?.send(current ? Commands.recordStop() : Commands.recordStart())
    }
    func checkHealth() {
        if let deadline=recordDeadline,now >= deadline {
            onSessionEvent?("record_confirmation_timeout","4s; no_camera_record_state_confirmation")
            recordPending=nil; recordDeadline=nil; recordError="录像请求未确认，请检查相机"
        }
        guard connected else { return }
        let evidence=healthEvidence()
        if evidence.classification != lastHealthClassification {
            lastHealthClassification=evidence.classification
            onSessionEvent?("session_health_changed",evidence.classification)
        }
        if let reason=sessionHealth.disconnectReason(evidence) {
            disconnect(reason:reason); message="控制传输中断："+reason+"；停止未确认"
        }
        // Video silence or an unsupported status layout is not evidence of a disconnected camera.
        // A half-dead shared endpoint is handled once by the bounded video recovery policy.
    }
    func disconnect(reason:String = "user_request") {
        let wasConnected=connected
        if wasConnected { onSessionEvent?("session_will_close",reason) }
        captureVideoDiagnostic()
        videoRecoveryTask?.cancel(); videoRecoveryTask=nil; videoTimeoutTask?.cancel(); videoTimeoutTask=nil
        if wasConnected || lastDisconnect == nil { lastDisconnect = .init(uptime:now,reason:reason,wasConnected:connected,transportHealthy:transportHealthy,
            statusAge:statusAt.map{now-$0},poseAge:pose.map{now-$0.receivedAt},nativeWrites:nativeWrites,
            socketErrorCode:link?.lastSendError?.code,network:network.snapshot(at:now),evidence:healthEvidence()) }
        stopTargets(); scanTask?.cancel(); scanTask=nil; bluetooth.stopScan()
        connectRun?.retire(); connectRun=nil; heartbeat.stop(); exchange.stopBLEDrain(); exchange.retire(DjiAppleControlExchange.Error.disconnected)
        link?.close(); link=nil; bluetooth.disconnect(); decoder.close(); lastPresentedAt=nil
        lastAttitudeLength=nil; attitudeFrames=0; poseFrames=0; parameterAt=nil
        lastSubmittedAngles=nil; lastSubmittedNativePitch=nil; targetSubmissions=0; lastCommandIssue=nil; lastStopAttemptAt=nil
        connected=false; connectedAt=nil; unhealthySince=nil; sessionHealth = .init(); lastControlFrameAt=nil; pose=nil; status = .init(); statusAt=nil; recordingAt=nil
        recordPending=nil; recordDeadline=nil; wifiRequest=nil; message="未连接"
        if wasConnected { onDisconnected?() }
    }
    func healthEvidence() -> CameraHealthEvidence {
        let time=now
        return .init(now:time,connected:connected,endpointPresent:link != nil,endpointClosed:link?.isClosed ?? true,
            flowHealthy:transportHealthy,rebuilding:link?.isRebuilding == true && videoRecoveryTask != nil,
            cameraSubnetPresent:network.snapshot(at:time).cameraSubnetPresent,controlAt:lastControlFrameAt,
            videoAt:link?.incidentIngress.lastVideoDatagramAge.map{time-$0})
    }
}
struct CameraDisconnect:Codable {
    let uptime:Double; let reason:String; let wasConnected:Bool; let transportHealthy:Bool
    let statusAge:Double?; let poseAge:Double?; let nativeWrites:Int; let socketErrorCode:Int?
    let network:NetworkDiagnostic; let evidence:CameraHealthEvidence
}
