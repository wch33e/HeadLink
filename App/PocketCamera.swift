import Foundation
import Observation
import OpenCineDJI
import OpenCineDJIApple
import OpenCineMotion
import OpenCineApple
import HeadLinkCore

/// Production adapter. Wire values and connection sequencing come only from pinned OpenCine.
@MainActor @Observable final class PocketCamera {
    @ObservationIgnored private let clock:()->Double
    @ObservationIgnored private let suppliedControlEndpoint:(any CameraControlEndpoint)?
    init(clock:@escaping ()->Double = { ProcessInfo.processInfo.systemUptime },controlEndpoint:(any CameraControlEndpoint)? = nil) {
        self.clock=clock; suppliedControlEndpoint=controlEndpoint
    }
    private var controlEndpoint:(any CameraControlEndpoint)? {
        if let suppliedControlEndpoint { return suppliedControlEndpoint }
        return link
    }
    var sightings: [DjiAppleSighting] = []
    var message = "未连接"
    var connected = false
    var selected: DjiAppleSighting?
    @ObservationIgnored var pose: CameraPose?
    @ObservationIgnored var lastAttitudeLength:Int?
    @ObservationIgnored var attitudeFrames=0
    @ObservationIgnored var poseFrames=0
    @ObservationIgnored var attitudeTrace:DjiAppleAttitudeTrace?
    @ObservationIgnored private var lastStatusReceipt:[UInt16:Double]=[:]
    @ObservationIgnored var parameterAt:Double?
    @ObservationIgnored var lastSubmittedAngles:Angles?
    @ObservationIgnored var lastSubmittedNativePitch:Double?
    @ObservationIgnored var targetSubmissions=0
    @ObservationIgnored var lastCommandIssue:String?
    @ObservationIgnored var lastTargetRejection:CameraTargetRejection?
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
    @ObservationIgnored var sessionHealth=CameraSessionHealthPolicy()
    @ObservationIgnored let network=CameraNetworkObserver()
    @ObservationIgnored var onSessionEvent:((String,String)->Void)?
    @ObservationIgnored var sceneActive=true
    @ObservationIgnored var sessionSSID:String?
    @ObservationIgnored var resumeTarget:(sighting:DjiAppleSighting,ssid:String)?
    @ObservationIgnored let foregroundRecovery=ForegroundCameraRecovery()
    @ObservationIgnored var subscriptionAttempts=0
    @ObservationIgnored var lastSubscriptionAttemptAt:Double?
    var recoveryMessage:String?
    var canRetryOriginal:Bool { resumeTarget != nil && !connected && !foregroundRecovery.running }
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
    @ObservationIgnored lazy var exchange = DjiAppleControlExchange(
        endpoint:.init(writeBLE:{ [weak self] in self?.bluetooth.send($0) },writeDatalink:{ [weak self] frame in
            guard let link=self?.link else { return .skipped }; return .queued(link.send(frame))
        }),context:{ [weak self] in .init(canTransmit:self?.connected == true,reported:self?.status) })
    @ObservationIgnored private lazy var heartbeat = DjiAppleSessionHeartbeat(
        endpoint:.init(writeBLE:{ [weak self] in self?.bluetooth.send($0) },registerDatalink:{ [weak self] in self?.link?.reRegister() },transport:{ [weak self] in
            .init(lastVideoAt:self?.link?.lastVideoPacketAt?.timeIntervalSinceReferenceDate,
                lastSelfieFlipReplyAt:self?.link?.lastSelfieFlipReplyAt?.timeIntervalSinceReferenceDate,
                lastSelfieFlipSendAt:self?.link?.lastSelfieFlipSendAt?.timeIntervalSinceReferenceDate,
                rebuilding:self?.link?.isRebuilding ?? false)
        }),
        context:{ [weak self] in .init(live:self?.connected == true,ownedConnection:true,
            pathReady:DjiAppleWiFiJoiner.isCameraPathReady(),sceneActive:self?.sceneActive == true,holdsMonitor:false,foregroundChecking:self?.foregroundRecovery.running == true,feedRepairing:self?.videoRecoveryTask != nil) },event:{ [weak self] event in
            if event == .cameraPathLost { self?.disconnect(reason:"camera_path_lost") }
        })
    func heartbeatStartAfterRecovery() { heartbeat.start(monitorMaintenanceEnabled:true) }
    var now: Double { clock() }
    var freshPose: CameraPose? { guard let pose,pose.fresh(at:now) else { return nil }; return pose }
    var actualRecording: Bool? {
        guard connected,status.recordingReported,let t=recordingAt,now >= t,now-t <= 2 else { return nil }
        return status.isRecording
    }
    var previewLive: Bool { videoSample().live }
    var transportHealthy: Bool { connected && controlEndpoint?.isFlowHealthy == true }
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
        network.start(); sessionHealth = .init()
        decoder=MonitorLiveVideoRuntime(); decoder.onPresentedFrame={ [weak self] in self?.lastPresentedAt=self?.now }
        var transport=DjiAppleConnectionTransport(bluetooth:bluetooth)
        // Replace only the OS Wi-Fi action; retain upstream pairing, identity verification and registration.
        transport.network.joinAccessPoint={ [weak self] request in
            guard let self else { throw CancellationError() }
            sessionSSID=request.ssid
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
    func bindLink() {
        guard let link else { return }
        link.onTimedStatusFrame={ [weak self] frame,receivedAt in self?.receive(frame,receivedAt:receivedAt) }
        let source=decoder.sourceToken
        link.onAccessUnit={ [weak self] bytes in
            guard let self,self.connected else { return }
            lastCompleteAccessUnitAt=now
            if decoder.decode(accessUnit:bytes,source:source) { lastAcceptedSampleAt=now }
        }
        link.onVideoDiscontinuity={ [weak self] in self?.decoder.noteCompressedDiscontinuity() }
    }
    func receive(_ frame: Duml.Frame,receivedAt:Double) {
        guard receivedAt.isFinite else { return }
        lastControlFrameAt=max(lastControlFrameAt ?? receivedAt,receivedAt)
        exchange.receive(frame)
        if frame.cmdSet == 4,frame.cmdId == 5 { _=capturePose(); return }
        let key=UInt16(frame.cmdSet)<<8 | UInt16(frame.cmdId)
        guard receivedAt >= (lastStatusReceipt[key] ?? receivedAt) else { return }
        if CameraStatusDecoder.apply(frame,to:&status,model:selected?.model) {
            lastStatusReceipt[key]=receivedAt
            statusAt=max(statusAt ?? receivedAt,receivedAt)
            if frame.cmdSet == 4,frame.cmdId == 0x50 { parameterAt=receivedAt }
        }
        if frame.cmdSet == 2,frame.cmdId == 0x80,frame.payload.count >= 13 {
            recordingAt=receivedAt
            if now >= receivedAt,now-receivedAt <= 2 { recordError=nil }
            if recordPending == status.isRecording {
                onSessionEvent?("record_confirmed",status.isRecording ? "camera_reports_recording" : "camera_reports_stopped")
                recordPending=nil; recordDeadline=nil
            }
        }
        _=capturePose()
    }
    /// Reads the already parsed newest pose on the UDP queue, not queued historical Main callbacks.
    /// A delayed callback can never re-stamp or replace this slot with an older pose.
    @discardableResult func capturePose() -> CameraPose? {
        guard let link else { return pose }
        let snapshot=link.headLinkAttitudeSnapshot
        attitudeTrace=snapshot.trace; attitudeFrames=snapshot.trace.frames
        poseFrames=snapshot.trace.validFrames; lastAttitudeLength=snapshot.trace.payloadLength
        if let receivedAt=snapshot.trace.lastIngressAt {
            lastControlFrameAt=max(lastControlFrameAt ?? receivedAt,receivedAt)
            statusAt=max(statusAt ?? receivedAt,receivedAt)
        }
        guard let value=snapshot.pose,let receivedAt=snapshot.receivedAt,let native=value.nativePitchDeg else { pose=nil; return nil }
        status.gimbalModeFamily=snapshot.trace.modeFamilyRaw.flatMap(GimbalModeFamily.init(rawValue:))
        pose = .init(angles:.init(yaw:value.yawDeg,pitch:value.pitchDeg),nativePitch:native,receivedAt:receivedAt)
        return pose
    }
    func confirmWiFi() { wifiContinue=true }
    func startTargets() -> Bool {
        guard transportHealthy else { lastCommandIssue="控制传输未就绪，未建立目标队列"; return false }
        guard freshPose != nil else { lastCommandIssue="镜头姿态缺失或超过300ms，未建立目标队列"; return false }
        lastCommandIssue=nil; lastTargetRejection=nil
        stopTargets(); tokenCounter &+= 1; targetToken=tokenCounter; controlEndpoint?.beginNativeTargets(token:tokenCounter); return true
    }
    func submit(_ output: TrackingOutput) -> Bool { submitTarget(output).accepted }
    func submit(angles:Angles,nativePitch:Double) -> Bool { submitTarget(angles:angles,nativePitch:nativePitch).accepted }
    func submitTarget(_ output:TrackingOutput) -> TargetSubmission { submitTarget(angles:output.command,nativePitch:output.nativePitch) }
    func submitTarget(angles:Angles,nativePitch:Double) -> TargetSubmission {
        func reject(_ kind:CameraTargetRejection,_ detail:String) -> TargetSubmission {
            lastTargetRejection=kind; lastCommandIssue=detail; return .rejected(kind)
        }
        guard transportHealthy else { return reject(.transportUnavailable,"相机传输不可用") }
        guard let live=freshPose else { return reject(.poseUnavailable,"镜头姿态已过期或布局不受支持") }
        guard angles.finite,nativePitch.isFinite else { return reject(.encodingRejected,"目标角度数值无效") }
        let encoded=Angles(yaw:(angles.yaw*10).rounded()/10,pitch:(angles.pitch*10).rounded()/10)
        guard abs(encoded.yaw-live.angles.yaw) < 180 else {
            return reject(.pathUnreachable,"目标路径不可达：与实际yaw相隔至少180°，未发送穿越扇区指令；原校准保留，回到可达方向后明确恢复")
        }
        guard let token=targetToken else { return reject(.streamInactive,"目标流未启动或已经暂停") }
        guard let frame=Commands.gimbalTimedTarget(yawDeg:angles.yaw,nativePitchDeg:nativePitch,duration:0.1) else {
            return reject(.encodingRejected,"角度被已核实命令编码器拒绝")
        }
        guard controlEndpoint?.noteNativeTarget(frame,token:token) == true else {
            return reject(.mailboxRejected,"目标队列拒绝：需核查底层新鲜度、所有权或可达路径；未判定整机断连")
        }
        let encodedNative=(nativePitch*10).rounded()/10
        lastSubmittedAngles=encoded; lastSubmittedNativePitch=encodedNative; targetSubmissions += 1
        lastCommandIssue=nil; lastTargetRejection=nil
        return .accepted(encoded,nativePitch:encodedNative)
    }
    func retryStatusReports() {
        guard connected,sceneActive else { return }
        subscriptionAttempts=0; lastSubscriptionAttemptAt=nil
        onSessionEvent?("status_subscription_retry_requested","user_action; no_recording_state_assumed")
        checkHealth()
    }
    func refreshControlInfo() {
        guard connected else { return }
        _=link?.sendUntracked(Commands.gimbalParamsGet())
    }
    var followModeBlock:String? {
        followModeBlock(at:now)
    }
    func followModeBlock(at time:Double) -> String? {
        if let family=status.gimbalModeFamily, family != .follow { return "机身当前不是跟随模式，请在相机下拉菜单选择跟随" }
        if let parameterAt,time >= parameterAt,time-parameterAt < 3,status.gimbalParams?.tiltLock == .locked {
            return "相机报告俯仰已锁定，请在机身改为跟随模式"
        }
        return nil
    }
    var controlModeReadiness:String? {
        controlModeReadiness(at:now)
    }
    func controlModeReadiness(at time:Double) -> String? {
        if let reason=followModeBlock(at:time) { return reason }
        guard status.gimbalModeFamily == .follow,let pose,pose.fresh(at:time) else { return "等待真实Follow模式与新鲜姿态回报" }
        guard let parameterAt,time >= parameterAt,time-parameterAt < 3,let params=status.gimbalParams else { return "等待新鲜云台参数回报（每2秒自动查询）" }
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
        controlEndpoint?.endNativeTargets(token:token)
        // This command is notify-only; no claim that a stopped pose was confirmed.
    }
    func toggleRecording() {
        guard connected,recordPending == nil,let current=actualRecording else { return }
        lastCameraSetAt=now
        onSessionEvent?("record_requested",current ? "stop; awaiting_camera_report" : "start; awaiting_camera_report")
        recordError=nil; recordPending = !current; recordDeadline=now+4
        _=controlEndpoint?.send(current ? Commands.recordStop() : Commands.recordStart())
    }
    var recordBlocker:String? {
        if !connected { return "相机会话未连接" }
        if recordPending != nil { return "等待相机确认录像请求（最多4秒）" }
        if actualRecording == nil { return "录像状态回报缺失或超过2秒，正在有界恢复状态订阅" }
        return nil
    }
    func checkHealth() {
        if let deadline=recordDeadline,now >= deadline {
            recordPending=nil; recordDeadline=nil; recordError="录像请求4秒未确认，未假定成功；等待相机新状态后可重试"
            onSessionEvent?("record_confirmation_timeout","4s; no_assumed_record_state")
        }
        guard connected else { return }
        _=capturePose()
        let evidence=healthEvidence()
        if let reason=sessionHealth.disconnectReason(evidence) { disconnect(reason:reason); message="控制传输中断："+reason; return }
        // Read-only, same pinned subscription keys/IDs; not a connection or gimbal-mode reset.
        if sceneActive,(freshPose == nil || actualRecording == nil),subscriptionAttempts < 3,
            now-(connectedAt ?? now) >= 0.3,lastSubscriptionAttemptAt.map({now-$0 >= 1}) ?? true,
            link?.isRebuilding != true,foregroundRecovery.running == false {
            subscriptionAttempts += 1; lastSubscriptionAttemptAt=now
            link?.refreshStatusSubscriptions()
            onSessionEvent?("status_subscription_recovery","attempt=\(subscriptionAttempts)/3; pose_fresh=\(freshPose != nil); record_fresh=\(actualRecording != nil)")
        }
    }
    func healthEvidence() -> CameraHealthEvidence {
        let time=now
        return .init(now:time,connected:connected,endpointPresent:controlEndpoint != nil,endpointClosed:link?.isClosed ?? (controlEndpoint == nil),
            flowHealthy:transportHealthy,rebuilding:link?.isRebuilding == true && videoRecoveryTask != nil,
            cameraSubnetPresent:network.snapshot(at:time).cameraSubnetPresent,controlAt:lastControlFrameAt,
            videoAt:link?.incidentIngress.lastVideoDatagramAge.map{time-$0})
    }
    func disconnect(reason:String = "user_request",preservingRecovery:Bool = false) {
        let wasConnected=connected
        if !preservingRecovery { foregroundRecovery.cancel(); resumeTarget=nil; recoveryMessage=nil }
        onSessionEvent?("session_will_close",reason)
        captureVideoDiagnostic()
        videoRecoveryTask?.cancel(); videoRecoveryTask=nil; videoTimeoutTask?.cancel(); videoTimeoutTask=nil
        lastDisconnect = .init(uptime:now,reason:reason,wasConnected:connected,transportHealthy:transportHealthy,
            statusAge:statusAt.map{now-$0},poseAge:pose.map{now-$0.receivedAt},nativeWrites:nativeWrites,
            socketErrorCode:link?.lastSendError?.code)
        stopTargets(); scanTask?.cancel(); scanTask=nil; bluetooth.stopScan()
        connectRun?.retire(); connectRun=nil; heartbeat.stop(); exchange.stopBLEDrain(); exchange.retire(DjiAppleControlExchange.Error.disconnected)
        link?.close(); link=nil; bluetooth.disconnect(); decoder.close(); lastPresentedAt=nil
        lastAttitudeLength=nil; attitudeFrames=0; poseFrames=0; parameterAt=nil; attitudeTrace=nil; lastStatusReceipt=[:]
        lastSubmittedAngles=nil; lastSubmittedNativePitch=nil; targetSubmissions=0; lastCommandIssue=nil; lastTargetRejection=nil; lastStopAttemptAt=nil
        connected=false; connectedAt=nil; sessionHealth = .init(); lastControlFrameAt=nil; pose=nil; status = .init(); statusAt=nil; recordingAt=nil
        recordPending=nil; recordDeadline=nil; wifiRequest=nil; message="未连接"; sessionSSID=nil; network.stop()
        if wasConnected { onDisconnected?() }
    }
}
struct CameraDisconnect:Codable {
    let uptime:Double; let reason:String; let wasConnected:Bool; let transportHealthy:Bool
    let statusAge:Double?; let poseAge:Double?; let nativeWrites:Int; let socketErrorCode:Int?
}
