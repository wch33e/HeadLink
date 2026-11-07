import Foundation
import Observation
import UIKit
import HeadLinkCore
import OpenCineDJIApple

@MainActor @Observable final class AppModel {
    let camera:PocketCamera
    @ObservationIgnored private let readMotion:()->MotionReading
    let instanceID=UUID().uuidString
    @ObservationIgnored private var loggedInvalidation:UInt64=0
    @ObservationIgnored var controller=TrackingController()
    @ObservationIgnored var mobile=MobileFollow()
    @ObservationIgnored private var mobileReading:MotionReading?
    @ObservationIgnored private var mobilePose:CameraPose?
    @ObservationIgnored private var mobileEpoch:UInt64?
    var isMobile:Bool { mountMode == .movingRelative }
    var mobileGain:Double = 1 { didSet { pause(); UserDefaults.standard.set(mobileGain,forKey:"mobileGain") } }
    var reverseMobileYaw=false { didSet { pause(); UserDefaults.standard.set(reverseMobileYaw,forKey:"reverseMobileYaw") } }
    var reverseMobilePitch=false { didSet { pause(); UserDefaults.standard.set(reverseMobilePitch,forKey:"reverseMobilePitch") } }
    @ObservationIgnored var probe=MotionProbe()
    @ObservationIgnored var commissioning=CommissioningSession()
    var motionLabel="未准备好"
    var notice:String?
    var pauseReason:FollowPauseReason?
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
    @ObservationIgnored private var previousCalibrationReadiness:Bool?
    @ObservationIgnored private var previousRangeLimited=false
    @ObservationIgnored private var previousMotionSample:MotionSample?
    @ObservationIgnored private var lastMotionConsumerGap:Double?
    @ObservationIgnored private var lastMotionSourceErrors:Int?
    @ObservationIgnored private var lastMotionGeneration:UInt64?
    var axes:ControlAxes = .both { didSet { pause(); controller.axes=axes; UserDefaults.standard.set(axes.rawValue,forKey:"axes") } }
    var mountMode:MountMode = .fixed { didSet {
        if oldValue != mountMode {
            camera.stopTargets(); mobile = .init(); controller.pause(invalidateCalibration:controller.state == .calibrating)
            commissioning = .init(); showingCalibration=false; camera.allowMobileRecovery=isMobile
            UserDefaults.standard.set(mountMode.rawValue,forKey:"mountMode")
            notice=isMobile ? "移动相对模式：明确开始后才会发送目标" : "已切换固定模式；请明确开始"
            recordEvent("mount_mode_changed",detail:mountMode.rawValue)
            publishPresentation()
        }
    } }
    @ObservationIgnored private var feedback=FollowFeedbackMonitor()
    var feedbackReading:FollowFeedbackReading? { feedback.reading }
    var response:ResponseMode = .immediate { didSet { pause(); controller.response=response; UserDefaults.standard.set(response.rawValue,forKey:"response") } }
    @ObservationIgnored let motion:any HeadphoneMotionService
    @ObservationIgnored private var loop:Task<Void,Never>?
    @ObservationIgnored private var sceneState="initial"
    @ObservationIgnored private var motionRecovery=MotionRecoveryPolicy()
    @ObservationIgnored private var connectedBefore=false
    @ObservationIgnored private var lastSensor:Double?
    @ObservationIgnored private var rateAt=0.0
    @ObservationIgnored private var diagnosticAt=0.0
    @ObservationIgnored private var controlInfoAt=0.0
    @ObservationIgnored private var writesBefore=0
    @ObservationIgnored private var errorSince:Double?
    var headAge:Double? { controller.sample.map { now-$0.receivedAt } }
    var profileReady:Bool { controller.limits?.valid == true }
    var isFollowing:Bool { isMobile ? mobile.running : controller.state == .following }
    var trackingStatus:String {
        if isMobile { return mobileStatus }
        if controller.state == .stalePaused,calibrationBlockers.isEmpty,!controller.hasCalibration { return "输入已恢复，等待重新校准" }
        return stateLabel(controller.state)
    }
    var formalLimits:VerifiedLimits? { FormalFollowProfile.limits(model:camera.selected?.model.name,reportedFirmware:camera.status.firmware) }
    var gravityAvailable:Bool {
        guard let sample=controller.sample,let gravity=sample.gravity else { return false }
        return (try? HeadDirectionReference(origin:sample.attitude,gravity:gravity)) != nil
    }
    var rangeLimited:Bool {
        isFollowing && (isMobile ? mobile.limited && mobile.hold == nil : controller.output?.limitedByRange == true) && camera.freshPose != nil
    }
    var shortShootingStatus:String {
        if isMobile { return mobileStatus }
        if !camera.connected { return "相机未连接" }
        if !camera.transportHealthy { return "控制传输未就绪" }
        if controller.pose?.fresh(at:now) != true { return "等待镜头姿态" }
        if headAge.map({$0 >= 0 && $0 < 0.2}) != true { return "等待耳机姿态" }
        if camera.recordError != nil { return "录像请求未确认" }
        if rangeLimited { return "目标已限位" }
        if isFollowing { return "跟随中" }
        if controller.state == .calibrating { return "校准中" }
        if let issue=calibrationIssues.first {
            return ["mode":"等待云台模式","mount":"移动模式未验证","profile":"当前型号未支持","gravity":"等待耳机方向参考","experiment":"请先停止诊断实验"][issue.id] ?? "等待输入就绪"
        }
        if controller.startBlocker(at:now) == .outsideLimits { return "相机回报超出范围" }
        if !controller.hasCalibration { return "等待校准" }
        if controller.state == .userPaused,let pauseReason { return pauseReason.summary }
        return trackingStatus
    }
    var canCalibrate:Bool { calibrationBlockers.isEmpty }
    /// Shared by the live sheet and the action; evaluated against the same captured inputs/clock.
    var calibrationBlockers:[String] { calibrationIssues.map(\.message) }
    var calibrationIssues:[CalibrationIssue] {
        if isMobile { return mobileIssues }
        var result:[CalibrationIssue]=[]
        func add(_ id:String,_ message:String) { result.append(.init(id:id,message:message)) }
        if commissioning.running { add("experiment","旧诊断实验仍在进行，请先停止") }
        if !camera.connected { add("session","相机控制会话未连接") }
        if !camera.transportHealthy { add("transport","相机控制传输未就绪") }
        if formalLimits == nil { add("profile","当前识别型号尚无正式协议配置") }
        if let reason=camera.controlModeReadiness(at:now) { add("mode",reason) }
        if let pose=controller.pose {
            if !pose.fresh(at:now) { add("camera_pose",now < pose.receivedAt ? "镜头姿态时间晚于控制时钟" : String(format:"镜头姿态已失效（%.0f ms）",(now-pose.receivedAt)*1000)) }
        } else { add("camera_pose","尚未收到有效镜头姿态") }
        if !gravityAvailable { add("gravity","耳机重力参考缺失或头部接近竖直") }
        if let sample=controller.sample {
            if now < sample.receivedAt || now-sample.receivedAt >= 0.2 { add("head_pose",now < sample.receivedAt ? "耳机姿态时间晚于控制时钟" : String(format:"耳机姿态已失效（%.0f ms）",(now-sample.receivedAt)*1000)) }
        } else { add("head_pose","尚未收到有效耳机姿态") }
        return result
    }
    var currentIdentity:CommissioningIdentity {
        .init(model:camera.selected?.model.name ?? "",firmware:camera.status.firmware ?? "",
              firmwareSource:camera.status.firmware == nil ? "not-reported" : "camera-report")
    }
    var blockers:[String] { startIssues.map(\.message) }
    var startIssues:[CalibrationIssue] {
        if isMobile { return mobileIssues }
        var result:[CalibrationIssue]=[]
        func add(_ id:String,_ message:String) { result.append(.init(id:id,message:message)) }
        if !camera.connected { add("session","相机未连接") }
        if !camera.transportHealthy { add("transport","相机传输未就绪") }
        if !(headAge.map{$0 <= controller.freshnessThreshold} ?? false) { add("head_pose","未收到新鲜耳机姿态（需小于200ms）") }
        if !gravityAvailable { add("gravity","耳机重力参考缺失或头部接近竖直，无法建立水平朝向") }
        if controller.pose?.fresh(at:now) != true { add("camera_pose","镜头姿态缺失或超过300ms") }
        if let reason=camera.controlModeReadiness(at:now) { add("mode",reason) }
        if formalLimits == nil { add("profile","当前识别型号尚无正式协议配置；仅支持真实识别的Osmo Pocket 4") }
        if !profileReady { add("limits","机型协议范围尚未就绪") }
        if commissioning.running || commissioning.state == .awaitingConfirmation { add("experiment","旧诊断实验仍在进行，请先停止") }
        if let rejection=controller.startBlocker(at:now),!result.contains(where:{$0.message == rejection.message}) { add("controller",rejection.message) }
        return result
    }
    var canStart:Bool { blockers.isEmpty }
    init(camera suppliedCamera:PocketCamera? = nil,motion suppliedMotion:(any HeadphoneMotionService)? = nil,readMotion:(()->MotionReading)? = nil) {
        let camera=suppliedCamera ?? PocketCamera()
        let motion=suppliedMotion ?? HeadphoneMotion()
        self.camera=camera; self.motion=motion
        self.readMotion=readMotion ?? { motion.read() }
        now=camera.now
        axes=ControlAxes(rawValue:UserDefaults.standard.string(forKey:"axes") ?? "") ?? .both
        response=ResponseMode(rawValue:UserDefaults.standard.string(forKey:"response") ?? "") ?? .immediate
        controller.axes=axes; controller.response=response; controller.requiresGravityReference=true
        mountMode=MountMode(rawValue:UserDefaults.standard.string(forKey:"mountMode") ?? "fixed") ?? .fixed
        camera.allowMobileRecovery=isMobile
        let savedGain=UserDefaults.standard.double(forKey:"mobileGain")
        mobileGain=[0.5,0.75,1.0].contains(savedGain) ? savedGain : 1
        reverseMobileYaw=UserDefaults.standard.bool(forKey:"reverseMobileYaw")
        reverseMobilePitch=UserDefaults.standard.bool(forKey:"reverseMobilePitch")
        camera.onSessionEvent={ [weak self] kind,detail in
            guard let self else { return }
            recordEvent(kind,detail:detail)
            if kind == "foreground_camera_recovery",detail == "restored_no_motion" {
                notice=isMobile ? "相机通信已恢复；请明确开始，不追赶断连期间的动作" : "相机通信已恢复；跟随保持停止，请重新校准后明确开始"
            }
        }
        camera.onVideoEvent={ [weak self] kind,detail in
            guard let self else { return }
            recordEvent(kind,detail:detail)
            if kind == "video_repair_start",!isMobile,isFollowing {
                camera.stopTargets(); controller.pause(); pauseReason = .videoRecovery
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
            if camera.lastDisconnect?.wasConnected == true {
                recordEvent(camera.lastDisconnect?.reason == "app_background" ? "camera_background_close" : "camera_disconnect",detail:camera.lastDisconnect?.reason ?? "unknown")
            }
            controller.connectionChanged(false); connectedBefore=false; revokeExperiment()
            if camera.lastDisconnect?.wasConnected == true {
                notice=camera.lastDisconnect?.reason == "app_background" ? "后台主动关闭通信；返回后核对原设备恢复，跟随保持停止" : "相机连接中断："+(camera.lastDisconnect?.reason ?? "unknown")
            }
        }
    }
    func activate() {
        let entering=sceneState != "active"
        sceneState="active"
        if entering { motionRecovery.beginForeground(); recordEvent("scene_active",detail:"restore_acquisition_and_camera_only; no_automatic_motion") }
        recoverMotionIfNeeded()
        camera.resumeAfterForeground()
        guard loop == nil else { return }
        loop=Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }; step()
                do { try await Task.sleep(for:.milliseconds(25)) } catch { return }
            }
        }
    }
    func pauseForInactiveScene() {
        sceneState="inactive"; camera.pauseForInactiveScene()
        recordEvent("scene_inactive",detail:"停止运动但不重建会话；有效校准保留，绝不自动恢复")
        let wasFollowing=isFollowing
        camera.stopTargets(); mobile.pause()
        controller.pause(invalidateCalibration:controller.state == .calibrating,reason:.sceneInactive)
        if commissioning.running { commissioning.abort(.canceled); controller.limits=nil }
        if wasFollowing { pauseReason = .inactive; notice="应用暂时失去活动状态，已暂停跟随；请回到前台后明确恢复" }
        publishPresentation()
    }
    func suspendControl() {
        sceneState="background"
        recordEvent("scene_background",detail:"应用进入后台，停止控制并清除本次校准")
        camera.stopTargets(); mobile.invalidateReference(); controller.pause(invalidateCalibration:true,reason:.sceneBackground); motion.stop(); lastSensor=nil; probe.reset()
        revokeExperiment(reason:.sceneBackground); loop?.cancel(); loop=nil; UIApplication.shared.isIdleTimerDisabled=false
        publishPresentation()
    }
    func deactivate() {
        suspendControl()
        camera.suspendForBackground()
    }
    private func recoverMotionIfNeeded() {
        guard sceneState == "active" else { return }
        let reading=motion.read(),allowed=motion.authorization != .denied && motion.authorization != .restricted
        guard let action=motionRecovery.action(at:camera.now,available:motion.available,authorized:allowed,
            active:motion.active,sampleAt:reading.sample?.receivedAt) else { return }
        if action == .restart { motion.stop() }
        motion.start()
        recordEvent("motion_recovery_attempt",detail:"\(action); attempt=\(motionRecovery.attempts)/3; active=\(motion.active)")
    }
    private func synchronizeLimits() {
        let next=formalLimits
        if let old=controller.limits,let next,(old.model != next.model || old.firmware != next.firmware) {
            camera.stopTargets(); mobile.pause(); controller.pause(invalidateCalibration:true,reason:.configurationChanged)
            recordEvent("protocol_identity_changed",detail:"model_or_reported_firmware_changed")
        }
        if next == nil,controller.hasCalibration {
            camera.stopTargets(); mobile.pause(); controller.pause(invalidateCalibration:true,reason:.configurationChanged)
        }
        controller.limits=next
    }
    private func captureInputs() {
        let frame=ControlInputFrame.capture(readMotion:readMotion,readCamera:{camera.capturePose()},clock:{camera.now})
        now=frame.evaluatedAt; callbackHz=frame.motion.callbackHz
        mobileReading=frame.motion; mobilePose=frame.camera
        loopGap=lastStepAt.map{now-$0} ?? 0
        let wasFollowing=isFollowing
        let wasCalibrating=controller.state == .calibrating
        let sourceRestarted=frame.motion.sourceGeneration.map{lastMotionGeneration != nil && $0 != lastMotionGeneration} ?? false
        if sourceRestarted { lastMotionSourceErrors=nil; lastSensor=nil; previousMotionSample=nil; lastMotionConsumerGap=nil }
        if let generation=frame.motion.sourceGeneration { lastMotionGeneration=generation }
        let newSourceError=frame.motion.sourceErrorCount.map{$0 > (lastMotionSourceErrors ?? 0)} ?? false
        if let count=frame.motion.sourceErrorCount { lastMotionSourceErrors=count }
        if frame.motion.failed || newSourceError || sourceRestarted {
            if isMobile {
                if sourceRestarted { mobile.invalidateReference(); camera.stopTargets() }
                else { holdMobile(.headStale) }
            } else { camera.stopTargets() }
            controller.motionUnavailable(); probe.reset(); lastSensor=nil
            if sourceRestarted { recordEvent("motion_session_changed",detail:"new_generation; calibration_invalidated") }
            if newSourceError { recordEvent("motion_callback_error",detail:isMobile ? "mobile_hold; continuity_checked_before_resume" : (frame.motion.failed ? "callback_error_active" : "callback_error_recovered_before_read; calibration_still_invalidated")) }
        }
        if camera.connected != connectedBefore { controller.connectionChanged(camera.connected); connectedBefore=camera.connected }
        if let s=frame.motion.sample,s.sensorTime != lastSensor {
            lastMotionConsumerGap=previousMotionSample.map{s.receivedAt-$0.receivedAt}
            previousMotionSample=s
            controller.ingest(s); probe.ingest(s); lastSensor=s.sensorTime
            if probe.referenceChanged,s.fresh(at:now,threshold:0.2),(try? s.attitude.normalized()) != nil {
                // Display observer only. TrackingController already applied its own invalidation.
                probe.reset(); probe.ingest(s)
                recordEvent("observation_reference_rebuilt",detail:"fresh_real_sample; display_only; tracking_calibration_unchanged")
            }
        }
        if let p=frame.camera { controller.ingest(p) }
        let label:String
        if frame.motion.failed { label="耳机运动回调报告错误，请重新检查运动服务" }
        else if motion.authorization == .denied || motion.authorization == .restricted { label="运动权限未允许" }
        else if !motion.available { label="请在系统中连接支持运动数据的耳机" }
        else if headAge.map({$0 >= 0 && $0 < 0.2}) == true { label=controller.hasCalibration ? "运动采集正常" : "运动采集正常；跟随未校准" }
        else if !motion.active { label=motionRecovery.attempts >= 3 ? "运动服务未启动，自动恢复已达上限；可点重新获取姿态" : "运动服务未启动，等待恢复" }
        else { label="运动服务已启动，等待新姿态样本" }
        if motionLabel != label { motionLabel=label }
        let sourceReason=sourceRestarted ? "耳机运动会话已更换，原校准已失效" : ((frame.motion.failed || newSourceError) ? (frame.motion.failed ? "耳机运动回调报告错误" : "耳机曾报告回调错误，输入已恢复，但原校准已失效") : nil)
        if !isMobile && wasFollowing && !isFollowing { stopAfterInputFailure(reasonOverride:sourceReason) }
        if wasCalibrating,controller.state != .calibrating {
            let reason=sourceReason ?? controller.invalidation?.reason.message ?? inputFailureDescription()
            notice="校准已中断："+reason
            recordEvent("calibration_interrupted",detail:reason)
        }
    }
    func step() {
        recoverMotionIfNeeded()
        if camera.mobileRecoveryRequested,sceneState == "active" {
            camera.mobileRecoveryRequested=false
            if isMobile { camera.resumeAfterForeground() }
        }
        camera.checkHealth(); camera.checkVideoHealth(); captureInputs()
        loopGap=lastStepAt.map{now-$0} ?? 0; lastStepAt=now
        defer { publishPresentation() }
        synchronizeLimits()
        if !isMobile,let reason=camera.followModeBlock(at:now),(commissioning.state != .inactive || isFollowing || controller.hasCalibration) {
            revokeExperiment(reason:.modeChanged); notice=reason
        }
        if camera.connected,now-controlInfoAt >= 2 {
            camera.refreshControlInfo(); controlInfoAt=now
        }
        if !isMobile,isFollowing,controller.pose?.fresh(at:now) == true,let reason=camera.controlModeReadiness(at:now) {
            camera.stopTargets(); controller.pause(); pauseReason = .mode
            recordEvent("mode_readiness_paused",detail:reason)
            notice="跟随已暂停："+reason+"；恢复模式回报后可明确继续"
        }
        if controller.state == .calibrating {
            if let started=calibrationStarted,now-started > 12 { controller.pause(invalidateCalibration:true,reason:.calibrationTimeout); notice="校准未完成，请保持头部和机身静止后重试" }
            else {
                do { if try controller.collectCalibration(at:now) { showingCalibration=false; notice="已校准，请明确点击开始跟随"; recordEvent("calibration_completed",detail:"awaiting_explicit_start"); haptic() } }
                catch { recordEvent("calibration_interrupted",detail:inputFailureDescription()); notice="校准暂停："+inputFailureDescription() }
            }
        }
        if isMobile {
            stepMobile()
        } else if commissioning.running {
            if let command=commissioning.tick(at:now,pose:camera.freshPose) {
                if camera.submit(angles:command.angles,nativePitch:command.nativePitch) { commissioning.noteSubmitted() }
                else { commissioning.abort(.transport) }
            }
            if commissioning.state != .moving { camera.stopTargets() }
            if commissioning.state == .failed { notice=commissioningFailure(commissioning.failure) }
        } else if isFollowing {
            if let output=controller.tick(at:now) {
                let submission=camera.submitTarget(output)
                if case let .rejected(kind)=submission {
                    // A command rejection stops motion, but is not proof that the head reference changed.
                    // Genuine stale/jumped input independently invalidates calibration in the controller.
                    controller.pause(); camera.stopTargets(); pauseReason=kind == .pathUnreachable ? .path : .submission
                    recordEvent("target_rejected",detail:kind.rawValue+":"+(camera.lastCommandIssue ?? "unknown"))
                    notice="跟随已暂停："+(camera.lastCommandIssue ?? "目标命令被拒绝")+"；未判定相机断连，请查看诊断"
                }
                if case let .accepted(executable,nativePitch:encodedNative)=submission,isFollowing {
                    let previous=feedback.reading?.state
                    let check=feedback.update(command:executable,nativePitch:encodedNative,
                        transitioning:output.transitioning,pose:controller.pose,at:now)
                    if check.state == .diverged {
                        camera.stopTargets(); controller.pause(); pauseReason = .feedback
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
        if (UserDefaults.standard.bool(forKey:"recordDiagnostics") || commissioning.state != .inactive || profileReady),now-diagnosticAt >= 0.1 {
            diagnosticAt=now
            diagnostics.append(.init(uptime:now,state:isMobile ? mobileDiagnosticState : controller.state.rawValue,headAge:headAge,
                head:isMobile ? mobile.headAngles : controller.head,probe:probe.look,raw:isMobile ? mobile.goal : controller.rawTarget,command:camera.lastSubmittedAngles,
                actual:camera.freshPose?.angles,nativePitch:camera.freshPose?.nativePitch,callbackHz:callbackHz,sendHz:sendHz,
                testState:commissioning.state.rawValue,commandIssue:camera.lastCommandIssue,
                cameraAge:controller.pose.map{now-$0.receivedAt},loopGap:loopGap,
                headSensorTime:controller.sample?.sensorTime,motionConsumerGap:lastMotionConsumerGap,
                motionSource:motion.diagnostic,attitudeTrace:camera.attitudeTrace,
                showingCalibration:showingCalibration,calibrationReady:canCalibrate,calibrationBlockers:calibrationBlockers,
                scene:sceneState,motionActive:motion.active,motionRecoveryAttempts:motionRecovery.attempts,
                network:camera.network.snapshot(at:now),recordingAt:camera.recordingAt,recordBlocker:camera.recordBlocker))
            if diagnostics.count > 6000 { diagnostics.removeFirst(diagnostics.count-6000) }
        }
    }
    private func publishPresentation() {
        if rangeLimited != previousRangeLimited {
            previousRangeLimited=rangeLimited
            let detail=controller.output.map{String(format:"raw=%.2f,%.2f; limited=%.2f,%.2f",$0.raw.yaw,$0.raw.pitch,$0.limited.yaw,$0.limited.pitch)} ?? "no_active_limited_output"
            recordEvent(rangeLimited ? "range_limited" : "range_clear",detail:detail)
        }
        if previousCalibrationReadiness != canCalibrate {
            previousCalibrationReadiness=canCalibrate
            recordEvent("calibration_readiness",detail:canCalibrate ? "inputs_ready" : calibrationBlockers.joined(separator:"；"))
        }
        if let invalidation=controller.invalidation,invalidation.sequence != loggedInvalidation {
            loggedInvalidation=invalidation.sequence
            recordEvent("calibration_invalidated",detail:invalidation.reason.rawValue)
        }
        let state=ControlPresentation(mobileState:isMobile ? mobileDiagnosticState : nil,state:controller.state,canStart:isFollowing ? false : canStart,
            canCalibrate:canCalibrate,profileReady:profileReady,hasCalibration:controller.hasCalibration,
            cameraFresh:camera.freshPose != nil,controlFresh:camera.controlReceiveFresh,previewLive:camera.previewLive,
            pictureAspect:Double(camera.decoder.pictureAspect),firmware:camera.status.firmware,recording:camera.actualRecording,
            recordingSeconds:camera.actualRecording == true ? camera.status.recordElapsedSec : 0,
            testState:commissioning.state,receiptCount:commissioning.receipts.count,
            probeReady:probe.movementObserved,rangeLimited:rangeLimited)
        let update=presentationGate.updates(control:state,at:camera.now)
        if update.controls { controlRevision &+= 1 }
        if update.telemetry { telemetryRevision &+= 1 }
    }
    private func recordEvent(_ kind:String,detail:String) {
        let time=camera.now
        events.append(.init(uptime:time,kind:kind,detail:detail,state:isMobile ? mobileDiagnosticState : controller.state.rawValue,
            hasCalibration:isMobile ? mobile.reference != nil : controller.hasCalibration,cameraConnected:camera.connected,
            transportHealthy:camera.transportHealthy,headAge:controller.sample.map{time-$0.receivedAt},
            cameraAge:camera.pose.map{time-$0.receivedAt},loopGap:loopGap,nativeWrites:camera.nativeWrites,connectionEpoch:camera.connectionEpoch,calibrationID:controller.calibrationID,
            mode:camera.modeSummary,firmware:currentIdentity.firmware,cameraAngles:camera.pose?.angles))
        if events.count > 300 { events.removeFirst(events.count-300) }
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
        case .referenceJump:return controller.invalidation?.reason.message ?? "耳机参考跳变或控制器收到的样本间隔超过200ms"
        case .vertical:return "头部接近竖直，方向解算不可用"
        case .invalidQuaternion:return "耳机姿态数值无效"
        case .unavailable:return "当前控制配置不可用"
        case .stale:return String(format:"控制节拍失效（本轮间隔%.0f ms）",loopGap*1000)
        default:return "控制状态失效：\(controller.failure.map{String(describing:$0)} ?? controller.state.rawValue)"
        }
    }
    private func stopAfterInputFailure(reasonOverride:String? = nil) {
        camera.stopTargets()
        let reason=reasonOverride ?? inputFailureDescription()
        recordEvent("input_paused",detail:reason)
        notice="跟随已暂停："+reason+"；需要重新校准。这不等同于相机断连。"
    }
    func resetProbe() { defer { publishPresentation() }; probe.reset(); notice="头部观察零点已重设；请分别左右转头、抬头低头，仅用于检查数据，不会转动云台" }
    func retryMotion() { mobile.invalidateReference(); motionRecovery.beginForeground(); defer { publishPresentation() }; motion.stop(); lastSensor=nil; controller.motionUnavailable(); probe.reset(); camera.stopTargets(); motion.start() }
    func revokeExperiment(reason:CalibrationInvalidationReason = .configurationChanged) { defer { publishPresentation() };
        camera.stopTargets(); mobile.pause(); controller.pause(invalidateCalibration:true,reason:reason); controller.limits=nil
        commissioning = .init(); errorSince=nil
    }
    func calibrate() {
        if isMobile { startMobile(run:mobile.running, recenter:true); return }
        defer { publishPresentation() }
        camera.checkHealth(); camera.stopTargets()
        captureInputs(); synchronizeLimits()
        guard canCalibrate else { notice=calibrationBlockers.joined(separator:"；"); recordEvent("calibration_rejected",detail:notice ?? "unknown"); return }
        do { try controller.beginCalibration(at:now); probe.reset(); if let sample=controller.sample { probe.ingest(sample) }; calibrationStarted=now; showingCalibration=true; notice=nil; recordEvent("calibration_started",detail:"user_action") }
        catch { notice="校准未开始："+((error as? TrackingError) == .gravityUnavailable ? "耳机重力参考不可用" : String(describing:error)); recordEvent("calibration_rejected",detail:notice ?? "unknown") }
    }
    func start() {
        if isMobile { startMobile(run:true, recenter:false); return }
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
            captureInputs(); try controller.start(at:now); feedback = .init(); errorSince=nil; pauseReason=nil
            recordEvent("following_started",detail:"native_queue_armed")
            notice="固定机身1∶1方向跟随中；倍率1.00，超出协议可达范围会明确限位"; haptic()
        } catch {
            controller.pause(); camera.stopTargets(); pauseReason = .start
            recordEvent("start_rejected",detail:String(describing:error))
            notice="跟随未启动："+(controller.lastStartRejection?.message ?? String(describing:error))
        }
    }
    func pause() { defer { publishPresentation() };
        pauseReason = .user
        recordEvent("user_paused",detail:"user_action")
        camera.stopTargets(); mobile.pause(); controller.pause(); errorSince=nil
        if commissioning.running { commissioning.abort(.canceled); controller.limits=nil }
        notice="跟随已暂停；已尝试发送停止，未收到停止ACK。机身移动时不保证锁定世界方向。"
    }
    func clearCalibration(reason:String = "user_action") { defer { publishPresentation() }; camera.stopTargets(); mobile.invalidateReference(); controller.pause(invalidateCalibration:true,reason:.userCleared); recordEvent("calibration_clear_requested",detail:reason) }
    var feedbackSummary:String {
        if isMobile { return "移动相对控制：镜头回报用于当前目标与安全检查，不以世界锁定误差判定断连" }
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
                controllerState:isMobile ? mobileDiagnosticState : controller.state.rawValue,trackingFailure:controller.failure.map{String(describing:$0)},
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
                mountMode:isMobile ? "movingRelative" : "fixed",gravityReferenceRequired:controller.requiresGravityReference,feedback:isMobile ? nil : feedback.reading,
                mobileGoal:isMobile ? mobile.goal : nil,mobileHold:isMobile ? mobile.hold?.rawValue : nil,
                mobileReference:isMobile ? mobile.reference : nil,mobileBodyAttitudeAvailable:isMobile ? false : nil,
                calibrationCameraAngles:controller.calibrationCameraPose?.angles,calibrationNativePitch:controller.calibrationCameraPose?.nativePitch,
                headQuaternion:controller.sample?.attitude,headGravity:controller.sample?.gravity,directionReference:controller.directionReference,
                motionSource:motion.diagnostic,motionConsumerGap:lastMotionConsumerGap,attitudeTrace:camera.attitudeTrace,
                calibrationReady:canCalibrate,calibrationBlockers:calibrationBlockers,showingCalibration:showingCalibration,
                provenance:BuildProvenance.current,sceneState:sceneState,motionServiceActive:motion.active,
                motionRecoveryAttempts:motionRecovery.attempts,network:camera.network.snapshot(at:camera.now),
                cameraRecovery:camera.recoveryMessage,subscriptionRecoveryAttempts:camera.subscriptionAttempts,
                recordingAt:camera.recordingAt,actualRecording:camera.actualRecording,recordPending:camera.recordPending,
                recordError:camera.recordError,recordBlocker:camera.recordBlocker)
            try encoder.encode(DiagnosticExport(schema:7,generatedAt:Date(),context:context,rows:diagnostics)).write(to:url,options:.atomic)
            exportURL=url
        } catch { notice="诊断导出失败，请重试" }
    }
}
struct CalibrationIssue:Identifiable,Equatable { let id:String; let message:String }

struct DiagnosticRow:Codable {
    let uptime:Double; let state:String; let headAge:Double?
    let head:Angles?; let probe:Angles?; let raw:Angles?; let command:Angles?; let actual:Angles?; let nativePitch:Double?
    let callbackHz:Double; let sendHz:Double; let testState:String; let commandIssue:String?
    let cameraAge:Double?; let loopGap:Double; let headSensorTime:Double?; let motionConsumerGap:Double?
    let motionSource:MotionDeliveryDiagnostic; let attitudeTrace:DjiAppleAttitudeTrace?
    let showingCalibration:Bool; let calibrationReady:Bool; let calibrationBlockers:[String]
    let scene:String; let motionActive:Bool; let motionRecoveryAttempts:Int; let network:NetworkDiagnostic
    let recordingAt:Double?; let recordBlocker:String?
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
    let mobileGoal:Angles?; let mobileHold:String?; let mobileReference:HeadDirectionReference?; let mobileBodyAttitudeAvailable:Bool?
    let calibrationCameraAngles:Angles?; let calibrationNativePitch:Double?
    let headQuaternion:Quaternion?; let headGravity:DirectionVector?; let directionReference:HeadDirectionReference?
    let motionSource:MotionDeliveryDiagnostic; let motionConsumerGap:Double?; let attitudeTrace:DjiAppleAttitudeTrace?
    let calibrationReady:Bool; let calibrationBlockers:[String]; let showingCalibration:Bool; let provenance:BuildProvenance?
    let sceneState:String; let motionServiceActive:Bool; let motionRecoveryAttempts:Int; let network:NetworkDiagnostic
    let cameraRecovery:String?; let subscriptionRecoveryAttempts:Int; let recordingAt:Double?; let actualRecording:Bool?; let recordPending:Bool?; let recordError:String?; let recordBlocker:String?
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
    let mobileState:String?; let state:TrackingState; let canStart:Bool; let canCalibrate:Bool; let profileReady:Bool; let hasCalibration:Bool
    let cameraFresh:Bool; let controlFresh:Bool; let previewLive:Bool; let pictureAspect:Double; let firmware:String?; let recording:Bool?; let recordingSeconds:Int
    let testState:CommissioningState; let receiptCount:Int; let probeReady:Bool; let rangeLimited:Bool
}
struct ControlEvent:Codable {
    let uptime:Double; let kind:String; let detail:String; let state:String; let hasCalibration:Bool
    let cameraConnected:Bool; let transportHealthy:Bool; let headAge:Double?; let cameraAge:Double?
    let loopGap:Double; let nativeWrites:Int; let connectionEpoch:UInt64; let calibrationID:UInt64
    let mode:String; let firmware:String; let cameraAngles:Angles?
}

extension AppModel {
    private var mobileDiagnosticState:String {
        (mobile.running ? "mobile_active" : "mobile_stopped") + (mobile.hold.map { ":" + $0.rawValue } ?? "")
            + (mobile.limited ? ":limited" : "") + (mobile.reference == nil ? ":no_reference" : "")
    }
    private var mobileStatus:String {
        if !camera.connected { return "相机未连接" }
        if !camera.transportHealthy { return "控制传输暂缓" }
        if let hold=mobile.hold {
            switch hold {
            case .headStale:return mobile.running ? "等耳机数据" : "耳机已暂停"
            case .cameraStale:return "等镜头回报"
            case .mode:return "等相机 Follow"
            case .path:return "转动路径受限"
            case .command:return mobile.running ? "命令暂缓" : "命令失败 · 已停"
            case .feedback:return "回报偏差 · 已停"
            case .scheduler:return "控制节拍暂缓"
            case .reference:return mobile.reference == nil ? "请重新居中" : "等姿态可用"
            case .transport:return "控制传输暂缓"
            }
        }
        if rangeLimited { return "目标到转动边界" }
        if mobile.running { return "移动相对控制" }
        return mobileIssues.first?.message ?? "移动相对 · 等待开始"
    }
    private var mobileIssues:[CalibrationIssue] {
        var list:[CalibrationIssue]=[]
        if sceneState == "inactive" || sceneState == "background" { list.append(.init(id:"scene",message:"返回前台后开始")) }
        if !camera.connected { list.append(.init(id:"session",message:"相机未连接")) }
        else if !camera.transportHealthy { list.append(.init(id:"transport",message:"控制传输未就绪")) }
        if mobileReading?.failed != false || mobileReading?.sample?.fresh(at:now,threshold:0.2) != true {
            list.append(.init(id:"head_pose",message:"等待新鲜耳机姿态"))
        } else if !gravityAvailable { list.append(.init(id:"gravity",message:"耳机方向参考不可用")) }
        if let limits=formalLimits {
            if let p=mobilePose,p.fresh(at:now) {
                if limits.clamp(p.angles) != p.angles { list.append(.init(id:"camera_range",message:"镜头回报超出既有范围")) }
                if let mode=camera.controlModeReadiness(at:now) { list.append(.init(id:"mode",message:mode)) }
            } else { list.append(.init(id:"camera_pose",message:"等待新鲜镜头回报")) }
        } else { list.append(.init(id:"profile",message:"当前型号无已核对协议范围")) }
        return list
    }
    private func startMobile(run:Bool,recenter:Bool) {
        defer { publishPresentation() }
        captureInputs(); synchronizeLimits()
        guard mobileIssues.isEmpty else {
            notice=mobileIssues.map(\.message).joined(separator:"；")
            recordEvent("mobile_start_blocked",detail:notice ?? "input_unavailable"); return
        }
        camera.stopTargets()
        // The synchronous stop may consume the freshness budget.
        captureInputs()
        guard mobileIssues.isEmpty,let freshHead=mobileReading?.sample,let freshPose=mobilePose else {
            mobile.pause(); notice="停止交接后输入已过期，请等新数据"; return
        }
        do {
            try mobile.start(sample:freshHead,pose:freshPose,at:now)
            if !run { mobile.pause() }
            mobileEpoch=camera.connectionEpoch; pauseReason=nil
            notice=recenter ? "已更新头部参考；未发出物理回中命令" : "移动相对控制：转头拨动，静止时让相机自身 Follow 接管"
            recordEvent(recenter ? "mobile_head_recentered" : "mobile_started",detail:"current_pose_seeded; no_center_motion")
        } catch { mobile.invalidateReference(); notice="头部参考不可用，请自然平视后再试" }
    }
    private func holdMobile(_ reason:MobileHold) {
        if mobile.interrupt(reason,at:now) {
            camera.stopTargets()
            recordEvent("mobile_hold",detail:reason.rawValue)
        }
    }
    private func stepMobile() {
        guard mobile.running else { camera.stopTargets(); return }
        guard camera.connectionEpoch == mobileEpoch,camera.connected else {
            mobile.pause(); camera.stopTargets(); recordEvent("mobile_session_changed",detail:"explicit_start_required"); return
        }
        guard camera.transportHealthy else { holdMobile(.transport); return }
        guard mobileReading?.failed == false else { holdMobile(.headStale); return }
        guard let limits=formalLimits else { mobile.pause(); camera.stopTargets(); recordEvent("mobile_profile_unavailable",detail:"no_motion"); return }
        if mobilePose?.fresh(at:now) == true,camera.controlModeReadiness(at:now) != nil { holdMobile(.mode); return }
        let previousHold=mobile.hold
        switch mobile.tick(head:mobileReading?.sample,pose:mobilePose,limits:limits,axes:axes,response:response,
                           gain:mobileGain,reverseYaw:reverseMobileYaw,reversePitch:reverseMobilePitch,at:now) {
        case .idle:
            if let previousHold,mobile.hold == nil { recordEvent("mobile_resumed",detail:previousHold.rawValue+"; no_catchup") }
        case .stop:
            camera.stopTargets(); recordEvent("mobile_motion_stopped",detail:mobile.hold?.rawValue ?? "settle_budget")
        case .rebase:
            camera.stopTargets()
            recordEvent("mobile_live_pose_rebase",detail:"one_timed_move_lead_exceeded; no_old_target_or_calibration_reset")
        case .referenceLost:
            camera.stopTargets(); notice="耳机参考不连续，请平视并重新居中"
            recordEvent("mobile_reference_lost",detail:"sensor_clock_or_quaternion_discontinuity")
        case let .target(angles,nativePitch,expiry):
            if !camera.hasTargetStream,!camera.startTargets() { holdMobile(.command); return }
            if case let .rejected(kind)=camera.submitTarget(angles:angles,nativePitch:nativePitch,deadline:expiry) {
                recordEvent("mobile_target_rejected",detail:kind.rawValue+":"+(camera.lastCommandIssue ?? "unknown"))
                switch kind {
                case .pathUnreachable:holdMobile(.path)
                case .poseUnavailable:holdMobile(.cameraStale)
                case .transportUnavailable:holdMobile(.transport)
                default:holdMobile(.command)
                }
            }
        }
    }
}
