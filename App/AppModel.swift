import Foundation
import Observation
import UIKit
import HeadLinkCore

@MainActor @Observable final class AppModel {
    let camera=PocketCamera()
    let instanceID=UUID().uuidString
    @ObservationIgnored private var loggedInvalidation:UInt64=0
    @ObservationIgnored var controller=TrackingController()
    @ObservationIgnored var probe=MotionProbe()
    @ObservationIgnored var commissioning=CommissioningSession()
    var motionLabel="未准备好"
    var notice:String?
    @ObservationIgnored var callbackHz=0.0
    @ObservationIgnored var sendHz=0.0
    @ObservationIgnored var now=ProcessInfo.processInfo.systemUptime
    @ObservationIgnored var diagnostics:[DiagnosticRow]=[]
    var exportURL:URL?
    var showingCalibration=false
    var showingCommissioning=false
    @ObservationIgnored var calibrationStarted:Double?
    var controlRevision=0
    var telemetryRevision=0
    @ObservationIgnored private var presentationGate=PresentationGate<ControlPresentation>()
    @ObservationIgnored private var lastStepAt:Double?
    @ObservationIgnored private var loopGap=0.0
    @ObservationIgnored private var events:[ControlEvent]=[]
    @ObservationIgnored var incidentHistory:[CameraIncidentSample]=[]
    @ObservationIgnored private var incidentAt=0.0
    @ObservationIgnored private var lastConnectedObservationAt:Double?
    @ObservationIgnored private var sceneObservation="not_observed"
    @ObservationIgnored private var scenario="unmarked"
    @ObservationIgnored private var wasRangeLimited=false
    var axes:ControlAxes = .both { didSet { pause(); controller.axes=axes; UserDefaults.standard.set(axes.rawValue,forKey:"axes") } }
    var mountMode:MountMode = .fixed { didSet {
        if oldValue != mountMode { revokeExperiment(); UserDefaults.standard.set(mountMode.rawValue,forKey:"mountMode") }
    } }
    @ObservationIgnored private var feedback=FollowFeedbackMonitor()
    var feedbackReading:FollowFeedbackReading? { feedback.reading }
    var response:ResponseMode = .immediate { didSet { pause(); controller.response=response; UserDefaults.standard.set(response.rawValue,forKey:"response") } }
    @ObservationIgnored let motion=HeadphoneMotion()
    @ObservationIgnored private var loop:Task<Void,Never>?
    @ObservationIgnored private var connectedBefore=false
    @ObservationIgnored private var lastSensor:Double?
    @ObservationIgnored private var rateAt=0.0
    @ObservationIgnored private var diagnosticAt=0.0
    @ObservationIgnored private var controlInfoAt=0.0
    @ObservationIgnored private var writesBefore=0
    @ObservationIgnored private var errorSince:Double?
    var headAge:Double? { controller.sample.map { max(0,now-$0.receivedAt) } }
    var profileReady:Bool { controller.limits?.valid == true }
    var isFollowing:Bool { controller.state == .following }
    var formalLimits:VerifiedLimits? { FormalFollowProfile.limits(model:camera.selected?.model.name,reportedFirmware:camera.status.firmware) }
    var gravityAvailable:Bool {
        guard let sample=controller.sample,let gravity=sample.gravity else { return false }
        return (try? HeadDirectionReference(origin:sample.attitude,gravity:gravity)) != nil
    }
    var canCalibrate:Bool {
        mountMode == .fixed && !commissioning.running && camera.transportHealthy && formalLimits != nil &&
        camera.controlModeReadiness == nil && camera.freshPose != nil && gravityAvailable && (headAge.map{$0 < 0.2} ?? false)
    }
    var currentIdentity:CommissioningIdentity {
        .init(model:camera.selected?.model.name ?? "",firmware:camera.status.firmware ?? "",
              firmwareSource:camera.status.firmware == nil ? "not-reported" : "camera-report")
    }
    var blockers:[String] {
        var result:[String]=[]
        if !camera.connected { result.append("相机未连接") }
        if !camera.transportHealthy { result.append("相机传输未就绪") }
        if mountMode != .fixed { result.append("移动机身补偿未验证：目前没有独立机身朝向，不允许用固定机身映射跟随，避免重复转动") }
        if !(headAge.map{$0 <= controller.freshnessThreshold} ?? false) { result.append("未收到新鲜耳机姿态（需小于200ms）") }
        if !gravityAvailable { result.append("耳机重力参考缺失或头部接近竖直，无法建立水平朝向") }
        if camera.freshPose == nil { result.append("镜头姿态缺失或超过300ms") }
        if let reason=camera.controlModeReadiness { result.append(reason) }
        if formalLimits == nil { result.append("当前识别型号尚无正式协议配置；仅支持真实识别的Osmo Pocket 4") }
        if !profileReady { result.append("机型协议范围尚未就绪") }
        if commissioning.running || commissioning.state == .awaitingConfirmation { result.append("旧诊断实验仍在进行，请先停止") }
        if let rejection=controller.startBlocker(at:now),!result.contains(rejection.message) { result.append(rejection.message) }
        if !controller.hasCalibration,let invalidation=controller.invalidation,invalidation.calibrationID > 0 { result.append("上次校准失效原因："+invalidation.reason.message) }
        return result
    }
    var canStart:Bool { blockers.isEmpty }
    init() {
        axes=ControlAxes(rawValue:UserDefaults.standard.string(forKey:"axes") ?? "") ?? .both
        response=ResponseMode(rawValue:UserDefaults.standard.string(forKey:"response") ?? "") ?? .immediate
        controller.axes=axes; controller.response=response; controller.requiresGravityReference=true
        mountMode=MountMode(rawValue:UserDefaults.standard.string(forKey:"mountMode") ?? "fixed") ?? .fixed
        camera.onSessionEvent={ [weak self] kind,detail in self?.recordEvent(kind,detail:detail) }
        camera.onVideoEvent={ [weak self] kind,detail in
            guard let self else { return }
            recordEvent(kind,detail:detail)
            if kind == "video_repair_start",isFollowing {
                camera.stopTargets(); controller.pause()
                notice="图传恢复开始，已暂停跟随；恢复后不会自动启动，控制状态与视频分别显示"
            }
            publishPresentation()
        }
        camera.onControlTransportReset={ [weak self] in
            guard let self else { return }
            camera.stopTargets(); controller.connectionChanged(false)
            revokeExperiment(reason:.connectionChanged)
            controller.connectionChanged(true); connectedBefore=true
            recordEvent("control_transport_reset",detail:"视频收流/组帧修复升级到共享UDP重建，校准已失效")
        }
        camera.onDisconnected={ [weak self] in
            guard let self else { return }
            if camera.lastDisconnect?.wasConnected == true { recordEvent("camera_disconnect",detail:camera.lastDisconnect?.reason ?? "unknown") }
            controller.connectionChanged(false); connectedBefore=false; revokeExperiment()
            if camera.lastDisconnect?.wasConnected == true { notice="相机连接中断："+(camera.lastDisconnect?.reason ?? "unknown") }
        }
    }
    func activate() {
        let changed=sceneObservation != "active"
        sceneObservation="active"; camera.network.start()
        if changed { recordEvent("scene_active",detail:"foreground; motion_never_auto_starts") }
        guard loop == nil else { return }
        motion.start()
        loop=Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }; step()
                do { try await Task.sleep(for:.milliseconds(25)) } catch { return }
            }
        }
    }
    func pauseForInactiveScene() {
        sceneObservation="inactive"
        recordEvent("scene_inactive",detail:"停止运动但不重建会话；有效校准保留，绝不自动恢复")
        let wasFollowing=isFollowing
        camera.stopTargets()
        controller.pause(invalidateCalibration:controller.state == .calibrating,reason:.sceneInactive)
        if commissioning.running { commissioning.abort(.canceled); controller.limits=nil }
        if wasFollowing { notice="应用暂时失去活动状态，已暂停跟随；请回到前台后明确恢复" }
        publishPresentation()
    }
    func suspendControl() {
        sceneObservation="background"
        recordEvent("scene_background",detail:"应用进入后台，停止控制并清除本次校准")
        camera.stopTargets(); controller.pause(invalidateCalibration:true,reason:.sceneBackground); motion.stop(); lastSensor=nil; probe.reset()
        revokeExperiment(reason:.sceneBackground); loop?.cancel(); loop=nil; UIApplication.shared.isIdleTimerDisabled=false
        publishPresentation()
    }
    func deactivate() {
        suspendControl()
        // Preserve the working manual Settings handoff and existing transport/video implementation.
        if camera.wifiRequest == nil { camera.disconnect(reason:"app_background") }
    }
    private func synchronizeLimits() {
        let next=formalLimits
        if let old=controller.limits,let next,(old.model != next.model || old.firmware != next.firmware) {
            camera.stopTargets(); controller.pause(invalidateCalibration:true,reason:.configurationChanged)
            recordEvent("protocol_identity_changed",detail:"model_or_reported_firmware_changed")
        }
        if next == nil,controller.hasCalibration {
            camera.stopTargets(); controller.pause(invalidateCalibration:true,reason:.configurationChanged)
        }
        controller.limits=next
    }
    private func captureInputs() {
        let frame=ControlInputFrame.capture(readMotion:{
            let value=motion.read()
            return .init(sample:value.0,callbackHz:value.1,failed:value.2)
        },readCamera:{camera.pose},clock:{ProcessInfo.processInfo.systemUptime})
        now=frame.evaluatedAt; callbackHz=frame.motion.callbackHz
        let wasFollowing=isFollowing
        if frame.motion.failed { camera.stopTargets(); controller.motionUnavailable(); probe.reset() }
        if camera.connected != connectedBefore { controller.connectionChanged(camera.connected); connectedBefore=camera.connected }
        if let s=frame.motion.sample,s.sensorTime != lastSensor { controller.ingest(s); probe.ingest(s); lastSensor=s.sensorTime }
        if let p=frame.camera { controller.ingest(p) }
        let label:String
        if frame.motion.failed { label="耳机运动回调报告错误，请重新检查运动服务" }
        else if motion.authorization == .denied || motion.authorization == .restricted { label="运动权限未允许" }
        else if !motion.available { label="请在系统中连接支持运动数据的耳机" }
        else if probe.referenceChanged { label="姿态参考中断或跳变，请重设观察零点并重新校准" }
        else { label=(headAge.map{$0 <= 0.2} ?? false) ? "数据正常" : "等待新的运动数据" }
        if motionLabel != label { motionLabel=label }
        if wasFollowing && !isFollowing { stopAfterInputFailure() }
    }
    private func step() {
        camera.checkHealth(); camera.checkVideoHealth(); captureInputs()
        loopGap=lastStepAt.map{now-$0} ?? 0; lastStepAt=now
        defer { publishPresentation() }
        synchronizeLimits()
        if let reason=camera.followModeBlock,(commissioning.state != .inactive || isFollowing || controller.hasCalibration) {
            recordEvent("camera_mode_incompatible",detail:reason)
            revokeExperiment(reason:.modeChanged); notice=reason
        }
        if camera.connected,now-controlInfoAt >= 2 {
            camera.refreshControlInfo(); controlInfoAt=now
        }
        if isFollowing,let reason=camera.controlModeReadiness {
            camera.stopTargets(); controller.pause()
            recordEvent("mode_readiness_paused",detail:reason)
            notice="跟随已暂停："+reason+"；恢复模式回报后可明确继续"
        }
        if controller.state == .calibrating {
            if let started=calibrationStarted,now-started > 12 { controller.pause(invalidateCalibration:true,reason:.calibrationTimeout); notice="校准未完成，请保持头部和机身静止后重试" }
            else {
                do { if try controller.collectCalibration(at:now) { showingCalibration=false; notice="已校准，请明确点击开始跟随"; recordEvent("calibration_completed",detail:"stable_head_and_camera; awaiting_explicit_start"); haptic() } }
                catch { recordEvent("calibration_interrupted",detail:inputFailureDescription()); notice="校准暂停："+inputFailureDescription() }
            }
        }
        if commissioning.running {
            if let command=commissioning.tick(at:now,pose:camera.freshPose) {
                if camera.submit(angles:command.angles,nativePitch:command.nativePitch) { commissioning.noteSubmitted() }
                else { commissioning.abort(.transport) }
            }
            if commissioning.state != .moving { camera.stopTargets() }
            if commissioning.state == .failed { notice=commissioningFailure(commissioning.failure) }
        } else if isFollowing {
            if let output=controller.tick(at:now) {
                if output.limitedByRange != wasRangeLimited {
                    wasRangeLimited=output.limitedByRange
                    recordEvent(wasRangeLimited ? "target_limit_reached" : "target_reachable_again",detail:"gain_1.00; calibration_preserved; session_preserved")
                }
                if !camera.submit(output) {
                    // A command rejection stops motion, but is not proof that the head reference changed.
                    // Genuine stale/jumped input independently invalidates calibration in the controller.
                    controller.pause(); camera.stopTargets()
                    recordEvent("target_rejected",detail:camera.lastCommandIssue ?? "unknown")
                    notice="跟随已暂停："+(camera.lastCommandIssue ?? "目标命令被拒绝")+"；未判定相机断连，请查看诊断"
                }
                if isFollowing {
                    let previous=feedback.reading?.state
                    let check=feedback.update(command:output.command,nativePitch:output.nativePitch,
                        transitioning:output.transitioning,pose:controller.pose,at:now)
                    if check.state == .diverged {
                        camera.stopTargets(); controller.pause()
                        recordEvent("feedback_diverged",detail:feedbackSummary)
                        notice="相机姿态回报持续偏离已停稳目标，已暂停；请检查模式、方向、机身是否移动。未改倍率或基准"
                    } else if check.state == .withinTolerance,previous != .withinTolerance {
                        recordEvent("feedback_in_tolerance",detail:feedbackSummary)
                    }
                }
            } else { stopAfterInputFailure() }
        } else { camera.stopTargets() }
        if now-rateAt >= 1 {
            let count=camera.nativeWrites
            sendHz=rateAt > 0 && count >= writesBefore ? Double(count-writesBefore)/(now-rateAt) : 0
            writesBefore=count; rateAt=now
        }
        captureIncident()
        if (UserDefaults.standard.bool(forKey:"recordDiagnostics") || commissioning.state != .inactive || profileReady),now-diagnosticAt >= 0.1 {
            diagnosticAt=now
            diagnostics.append(.init(uptime:now,state:controller.state.rawValue,headAge:headAge,
                head:controller.head,probe:probe.look,raw:controller.rawTarget,command:camera.lastSubmittedAngles,
                actual:camera.freshPose?.angles,nativePitch:camera.freshPose?.nativePitch,callbackHz:callbackHz,sendHz:sendHz,
                testState:commissioning.state.rawValue,commandIssue:camera.lastCommandIssue))
            if diagnostics.count > 6000 { diagnostics.removeFirst(diagnostics.count-6000) }
        }
    }
    private func publishPresentation() {
        if let invalidation=controller.invalidation,invalidation.sequence != loggedInvalidation {
            loggedInvalidation=invalidation.sequence
            recordEvent("calibration_invalidated",detail:invalidation.reason.rawValue)
        }
        let state=ControlPresentation(state:controller.state,canStart:isFollowing ? false : canStart,
            canCalibrate:canCalibrate,profileReady:profileReady,hasCalibration:controller.hasCalibration,
            cameraFresh:camera.freshPose != nil,controlFresh:camera.controlReceiveFresh,previewLive:camera.previewLive,
            pictureAspect:Double(camera.decoder.pictureAspect),firmware:camera.status.firmware,recording:camera.actualRecording,
            recordingSeconds:camera.actualRecording == true ? camera.status.recordElapsedSec : 0,
            testState:commissioning.state,receiptCount:commissioning.receipts.count,
            probeReady:probe.movementObserved)
        let update=presentationGate.updates(control:state,at:ProcessInfo.processInfo.systemUptime)
        if update.controls { controlRevision &+= 1 }
        if update.telemetry { telemetryRevision &+= 1 }
    }
    private func recordEvent(_ kind:String,detail:String) {
        let time=ProcessInfo.processInfo.systemUptime
        events.append(.init(uptime:time,kind:kind,detail:detail,state:controller.state.rawValue,
            hasCalibration:controller.hasCalibration,cameraConnected:camera.connected,
            transportHealthy:camera.transportHealthy,headAge:controller.sample.map{time-$0.receivedAt},
            cameraAge:camera.pose.map{time-$0.receivedAt},loopGap:loopGap,nativeWrites:camera.nativeWrites,connectionEpoch:camera.connectionEpoch,calibrationID:controller.calibrationID,
            mode:camera.modeSummary,firmware:currentIdentity.firmware,cameraAngles:camera.pose?.angles))
        if events.count > 300 { events.removeFirst(events.count-300) }
        captureIncident(event:kind+":"+detail)
    }
    func markComparison(_ group:String) {
        guard group == "A" || group == "B" else { return }
        if group == "A" { pause() }
        scenario=group == "A" ? "A_preview_follow_off" : "B_fixed_follow_body_movement_reproduction"
        recordEvent("comparison_marked",detail:scenario+"; B_requires_explicit_start; not_compensated_neck_mode")
        notice=group == "A" ? "A组已标记，跟随已暂停；仅预览，移动机身并核对录像是否响应。" : "B组已标记；这是旧固定模式的故障对照，尚无机身补偿。需你明确校准／开始，再重复A组动作。"
        publishPresentation()
    }
    private func captureIncident(event:String? = nil) {
        let t=ProcessInfo.processInfo.systemUptime
        if camera.connected { lastConnectedObservationAt=t }
        guard event != nil || camera.connected || (lastConnectedObservationAt.map{t-$0 < 30} ?? false) else { return }
        guard event != nil || t-incidentAt >= 0.2 else { return }
        incidentAt=t
        let e=camera.healthEvidence()
        incidentHistory.append(.init(uptime:t,scenario:scenario,scene:sceneObservation,
            network:camera.network.snapshot(at:t),session:e,classification:e.classification,
            connectionEpoch:camera.connectionEpoch,followingState:controller.state.rawValue,calibrationID:controller.calibrationID,
            hasCalibration:controller.hasCalibration,calibrationInvalidation:controller.invalidation,startRejection:controller.lastStartRejection,
            headAt:controller.sample?.receivedAt,headSensorTime:controller.sample?.sensorTime,headQuaternion:controller.sample?.attitude,headTarget:controller.head,
            rawTarget:controller.rawTarget,sentTarget:camera.lastSubmittedAngles,sentNativePitch:camera.lastSubmittedNativePitch,
            actualAngles:camera.pose?.angles,actualNativePitch:camera.pose?.nativePitch,poseAt:camera.pose?.receivedAt,cameraAttitude:camera.attitudeObservation,
            mode:camera.modeSummary,statusAt:camera.statusAt,parameterAt:camera.parameterAt,
            nativeWrites:camera.nativeWrites,targetSubmissions:camera.targetSubmissions,commandIssue:camera.lastCommandIssue,
            lastTrackedCommandWriteLanded:camera.link?.lastWriteLanded,lastSocketErrorCode:camera.link?.lastSendError?.code,
            stopAttemptAt:camera.lastStopAttemptAt,actualRecording:camera.actualRecording,recordingAt:camera.recordingAt,
            recordPending:camera.recordPending,recordError:camera.recordError,video:camera.videoSample(),
            videoRecoveryState:camera.videoPolicy.state.rawValue,videoRecoveryReason:camera.videoPolicy.reason,
            lastAcceptedSampleAt:camera.lastAcceptedSampleAt,sceneOrSessionEvent:event,
            bodyAttitudeObservation:"unavailable; iPhone_separate; lens_quaternion_not_body; full_joint_rotation_unqualified"))
        if incidentHistory.count > 1500 { incidentHistory.removeFirst(incidentHistory.count-1500) }
    }
    private func inputFailureDescription() -> String {
        guard camera.connected else { return "相机已断连，请查看断连原因" }
        guard let sample=controller.sample else { return "耳机未提供有效姿态" }
        let age=now-sample.receivedAt
        if age < 0 { return "控制时钟早于耳机样本，已停止（时序错误）" }
        if age > controller.freshnessThreshold { return String(format:"耳机姿态已过期（%.0f ms）",age*1000) }
        guard let pose=controller.pose else { return "未收到有效镜头姿态" }
        if !pose.fresh(at:now) { return String(format:"镜头姿态已失效（%.0f ms）",(now-pose.receivedAt)*1000) }
        switch controller.failure {
        case .referenceJump:return "耳机姿态参考跳变或回调间隔超过200ms"
        case .vertical:return "头部接近竖直，方向解算不可用"
        case .invalidQuaternion:return "耳机姿态数值无效"
        case .unavailable:return "当前控制配置不可用"
        case .stale:return String(format:"控制节拍失效（本轮间隔%.0f ms）",loopGap*1000)
        default:return "控制状态失效：\(controller.failure.map{String(describing:$0)} ?? controller.state.rawValue)"
        }
    }
    private func stopAfterInputFailure() {
        camera.stopTargets()
        let reason=inputFailureDescription()
        recordEvent("input_paused",detail:reason)
        notice="跟随已暂停："+reason+"；需要重新校准。这不等同于相机断连。"
    }
    func resetProbe() { defer { publishPresentation() }; probe.reset(); notice="头部观察零点已重设；请分别左右转头、抬头低头，仅用于检查数据，不会转动云台" }
    func retryMotion() { defer { publishPresentation() }; motion.stop(); lastSensor=nil; controller.motionUnavailable(); probe.reset(); camera.stopTargets(); motion.start() }
    func revokeExperiment(reason:CalibrationInvalidationReason = .configurationChanged) { defer { publishPresentation() };
        camera.stopTargets(); controller.pause(invalidateCalibration:true,reason:reason); controller.limits=nil
        commissioning = .init(); errorSince=nil
    }
    func calibrate() {
        defer { publishPresentation() }
        camera.checkHealth(); captureInputs()
        camera.stopTargets(); synchronizeLimits()
        guard canCalibrate else { notice=blockers.filter{!$0.contains("尚未校准")}.joined(separator:"；"); return }
        do { try controller.beginCalibration(at:now); calibrationStarted=now; showingCalibration=true; notice=nil; recordEvent("calibration_started",detail:"user_action") }
        catch { notice="校准未开始："+((error as? TrackingError) == .gravityUnavailable ? "耳机重力参考不可用" : String(describing:error)); recordEvent("calibration_rejected",detail:notice ?? "unknown") }
    }
    func start() {
        defer { publishPresentation() }
        camera.checkHealth(); captureInputs(); synchronizeLimits()
        recordEvent("start_requested",detail:"user_action")
        guard canStart else { notice=blockers.joined(separator:"；"); recordEvent("start_blocked",detail:notice ?? "unknown"); return }
        do {
            guard camera.startTargets() else {
                recordEvent("start_rejected_native",detail:camera.lastCommandIssue ?? "native_queue_unavailable")
                notice="跟随未启动："+(camera.lastCommandIssue ?? "目标队列不可用")+"；校准是否有效见当前状态"
                return
            }
            // Queue ownership is established without sending a target. Re-snapshot after
            // the synchronous UDP handoff, then establish the control-loop time origin.
            captureInputs(); try controller.start(at:now); feedback = .init(); errorSince=nil
            recordEvent("following_started",detail:"native_queue_armed")
            notice="固定机身1∶1方向跟随中；倍率1.00，超出协议可达范围会明确限位"; haptic()
        } catch {
            controller.pause(); camera.stopTargets()
            recordEvent("start_rejected",detail:String(describing:error))
            notice="跟随未启动："+(controller.lastStartRejection?.message ?? String(describing:error))
        }
    }
    func pause() { defer { publishPresentation() };
        recordEvent("user_paused",detail:"user_action")
        camera.stopTargets(); controller.pause(); errorSince=nil
        if commissioning.running { commissioning.abort(.canceled); controller.limits=nil }
        notice="跟随已暂停；已尝试发送停止，未收到停止ACK。机身移动时不保证锁定世界方向。"
    }
    func clearCalibration() { defer { publishPresentation() }; camera.stopTargets(); controller.pause(invalidateCalibration:true,reason:.userCleared) }
    var feedbackSummary:String {
        guard let r=feedback.reading else { return "相机姿态核对：尚未运行" }
        let state:String
        switch r.state {
        case .unavailable:state="回报不可用"
        case .settling:state="运动或等待停稳"
        case .withinTolerance:state="回报位于核对阈值内"
        case .mismatch:state="回报偏差观察中"
        case .diverged:state="回报持续偏离，已暂停"
        }
        guard let yaw=r.yawError,let pitch=r.pitchError,let native=r.nativePitchError else { return state }
        return String(format:"%@ · 回报差 yaw %.1f° / pitch %.1f° / 原生pitch %.1f°",state,yaw,pitch,native)
    }
    func haptic() { if UserDefaults.standard.bool(forKey:"haptics") { UIImpactFeedbackGenerator(style:.light).impactOccurred() } }
    func exportDiagnostics() {
        camera.captureVideoDiagnostic()
        do {
            let encoder=JSONEncoder(); encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
            let url=FileManager.default.temporaryDirectory.appendingPathComponent("HeadLink-diagnostics.json")
            let context=DiagnosticContext(iOS:UIDevice.current.systemVersion,model:camera.selected?.model.name,
                modelID:camera.selected?.modelId,reportedFirmware:camera.status.firmware,operatorFirmware:"",
                firmwareSource:currentIdentity.firmwareSource,mode:camera.modeSummary,attitudeLength:camera.lastAttitudeLength,
                attitudeFrames:camera.attitudeFrames,poseFrames:camera.poseFrames,probeMovementObserved:probe.movementObserved,
                motionAvailable:motion.available,motionAuthorization:Int(motion.authorization.rawValue),
                controllerState:controller.state.rawValue,trackingFailure:controller.failure.map{String(describing:$0)},
                blockers:blockers,receipts:commissioning.receipts,pendingReceipt:commissioning.pendingReceipt,
                limits:controller.limits,stopAttemptAt:camera.lastStopAttemptAt,
                targetSubmissions:camera.targetSubmissions,nativeWrites:camera.nativeWrites,
                lastSubmittedAngles:camera.lastSubmittedAngles,lastSubmittedNativePitch:camera.lastSubmittedNativePitch,
                lastCommandIssue:camera.lastCommandIssue,calibrationComplete:controller.hasCalibration,
                configurationSource:profileReady ? FormalFollowProfile.source : "none",
                events:events,lastDisconnect:camera.lastDisconnect,
                appVersion:Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String,
                buildNumber:Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String,
                appInstanceID:instanceID,connectionEpoch:camera.connectionEpoch,calibrationID:controller.calibrationID,
                lastStartRejection:controller.lastStartRejection,currentStartBlocker:controller.startBlocker(at:now),calibrationInvalidation:controller.invalidation,
                video:camera.videoDiagnostic,videoHistory:camera.videoHistory,
                mountMode:mountMode.rawValue,gravityReferenceRequired:controller.requiresGravityReference,feedback:feedback.reading,
                calibrationCameraAngles:controller.calibrationCameraPose?.angles,calibrationNativePitch:controller.calibrationCameraPose?.nativePitch,
                headQuaternion:controller.sample?.attitude,headGravity:controller.sample?.gravity,directionReference:controller.directionReference,
                incidents:incidentHistory)
            try encoder.encode(DiagnosticExport(schema:5,generatedAt:Date(),context:context,rows:diagnostics)).write(to:url,options:.atomic)
            exportURL=url
        } catch { notice="诊断导出失败，请重试" }
    }
}
struct DiagnosticRow:Codable {
    let uptime:Double; let state:String; let headAge:Double?
    let head:Angles?; let probe:Angles?; let raw:Angles?; let command:Angles?; let actual:Angles?; let nativePitch:Double?
    let callbackHz:Double; let sendHz:Double; let testState:String; let commandIssue:String?
}
struct DiagnosticContext:Codable {
    let iOS:String; let model:String?; let modelID:Int?; let reportedFirmware:String?; let operatorFirmware:String
    let firmwareSource:String; let mode:String; let attitudeLength:Int?; let attitudeFrames:Int; let poseFrames:Int
    let probeMovementObserved:Bool; let motionAvailable:Bool; let motionAuthorization:Int; let controllerState:String; let trackingFailure:String?
    let blockers:[String]; let receipts:[MovementReceipt]; let pendingReceipt:MovementReceipt?
    let limits:VerifiedLimits?; let stopAttemptAt:Double?
    let targetSubmissions:Int; let nativeWrites:Int; let lastSubmittedAngles:Angles?; let lastSubmittedNativePitch:Double?; let lastCommandIssue:String?
    let calibrationComplete:Bool; let configurationSource:String
    let events:[ControlEvent]; let lastDisconnect:CameraDisconnect?
    let appVersion:String?; let buildNumber:String?; let appInstanceID:String; let connectionEpoch:UInt64; let calibrationID:UInt64
    let lastStartRejection:TrackingStartRejection?; let currentStartBlocker:TrackingStartRejection?; let calibrationInvalidation:CalibrationInvalidation?
    let video:VideoDiagnostic?; let videoHistory:[VideoDiagnostic]
    let mountMode:String; let gravityReferenceRequired:Bool; let feedback:FollowFeedbackReading?
    let calibrationCameraAngles:Angles?; let calibrationNativePitch:Double?
    let headQuaternion:Quaternion?; let headGravity:DirectionVector?; let directionReference:HeadDirectionReference?
    let incidents:[CameraIncidentSample]
}
struct DiagnosticExport:Codable { let schema:Int; let generatedAt:Date; let context:DiagnosticContext; let rows:[DiagnosticRow] }
func commissioningFailure(_ reason:CommissioningError?) -> String {
    switch reason {
    case .stale:return "实验暂停：镜头姿态缺失或超过300ms"
    case .schedulerGap:return "实验暂停：控制节拍超过200ms"
    case .wrongDirection:return "实验停止：实际回报方向与目标相反，请导出诊断"
    case .crossAxisMovement:return "实验停止：另一轴出现明显运动，请检查机身固定和云台模式"
    case .range:return "实验停止：回报超出本次目标或上游命令范围"
    case .timeout:return "实验停止：未能及时到位或收到足够停稳回报，请导出诊断"
    case .didNotHold:return "停止后回报仍有明显移动，实验未通过"
    case .transport:return "实验停止：目标队列或相机传输拒绝，详见命令链路状态"
    case .modeChanged:return "实验停止：云台模式发生变化"
    case .canceled:return "用户停止实验；该项未通过"
    default:return "实验条件不满足，请检查设备信息、数据时效和确认步骤"
    }
}

private struct ControlPresentation:Equatable {
    let state:TrackingState; let canStart:Bool; let canCalibrate:Bool; let profileReady:Bool; let hasCalibration:Bool
    let cameraFresh:Bool; let controlFresh:Bool; let previewLive:Bool; let pictureAspect:Double; let firmware:String?; let recording:Bool?; let recordingSeconds:Int
    let testState:CommissioningState; let receiptCount:Int; let probeReady:Bool
}
struct ControlEvent:Codable {
    let uptime:Double; let kind:String; let detail:String; let state:String; let hasCalibration:Bool
    let cameraConnected:Bool; let transportHealthy:Bool; let headAge:Double?; let cameraAge:Double?
    let loopGap:Double; let nativeWrites:Int; let connectionEpoch:UInt64; let calibrationID:UInt64
    let mode:String; let firmware:String; let cameraAngles:Angles?
}
