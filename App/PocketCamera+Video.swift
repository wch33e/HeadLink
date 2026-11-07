import Foundation
import HeadLinkCore
import OpenCineDJIApple
import OpenCineApple

extension PocketCamera {
    var controlReceiveFresh:Bool { lastControlFrameAt.map{now-$0 <= 3} ?? false }
    func beginVideoSession() {
        connectionEpoch &+= 1; connectedAt=now; subscriptionAttempts=0; lastSubscriptionAttemptAt=nil
        videoPolicy = .init(); videoCheckAt=0; videoHistory=[]; videoHistoryAt=0
        lastCompleteAccessUnitAt=nil; lastAcceptedSampleAt=nil; lastPresentedAt=nil
        videoMessage="等待真实视频帧"
    }
    func videoSample() -> VideoPipelineSample {
        let time=now
        let ingress=link?.incidentIngress
        return .init(now:time,startedAt:connectedAt ?? time,connected:connected,transportReady:transportHealthy,
            packetAt:ingress?.lastVideoDatagramAge.map{time-$0},accessUnitAt:lastCompleteAccessUnitAt,
            decoderOutputAt:decoder.nativeOutputAge.map{time-$0},presentedAt:lastPresentedAt,
            decoderFailed:decoder.isDecoderWedged || decoder.displayedImageRemoved,
            awaitingKeyframe:decoder.awaitingIDR || decoder.referenceRecoveryNeeded,cameraSetAt:lastCameraSetAt,controlFrameAt:lastControlFrameAt)
    }
    func captureVideoDiagnostic() {
        let sample=videoSample(),metrics=decoder.nativeDecodeTotals,queue=link?.incidentQueue,ingress=link?.incidentIngress
        let snapshot=VideoDiagnostic(sample:sample,recoveryState:videoPolicy.state.rawValue,
            recoveryReason:videoPolicy.reason,attempts:videoPolicy.attempts,
            packetCount:link?.videoPackets,accessUnits:link?.accessUnits,receiveErrors:link?.receiveErrorCount,
            decodeSubmitted:metrics.submitted,decodeAccepted:metrics.accepted,decodeOutputs:metrics.output,
            lastAcceptedSampleAt:lastAcceptedSampleAt,
            presentationObservation:decoder.nativeOutputExpected ? "native_decode_and_presentation_callback" : "compressed_layer_enqueue_not_physical_display",
            queueFrames:queue?.count,queueBytes:queue?.bytes,queueOldestMs:queue?.ageMilliseconds,
            incompleteAccessUnits:queue?.incompleteAccessUnits,dropped:queue?.drops,
            socketGeneration:ingress?.socketGeneration,registrationSubmissions:ingress?.registrationSubmissions,
            lastRegistrationAge:ingress?.lastRegistrationSubmissionAge,
            sharedTransportRepairRunning:videoRecoveryTask != nil,lastControlFrameAt:lastControlFrameAt,
            controlReceiveFresh:controlReceiveFresh,transportHealthy:transportHealthy)
        videoDiagnostic=snapshot
        if sample.now-videoHistoryAt >= 1 {
            videoHistoryAt=sample.now; videoHistory.append(snapshot)
            if videoHistory.count > 180 { videoHistory.removeFirst(videoHistory.count-180) }
        }
    }
    func checkVideoHealth() {
        guard connected,now-videoCheckAt >= 0.25 else { return }
        videoCheckAt=now
        let input=videoSample()
        let action=videoPolicy.tick(input,busy:videoRecoveryTask != nil)
        captureVideoDiagnostic()
        let message:String
        if input.live { message="视频源帧持续更新" }
        else if videoPolicy.state == .failed { message="图传恢复未成功："+videoPolicy.reason+"；可手动重试图传，控制状态另行显示" }
        else if videoPolicy.state == .recovering { message="图传恢复中（\(videoPolicy.attempts)/3）："+videoPolicy.reason }
        else if videoPolicy.reason.contains("control_alive_shared_transport_kept") { message="图传恢复未成功；控制仍有回报，已保留控制会话，可手动重试图传" }
        else { message="视频暂停，正在检查接收、组帧和解码" }
        if videoMessage != message { videoMessage=message }
        guard let action,let endpoint=link else { return }
        onVideoEvent?("video_repair_start",action.rawValue+":"+videoPolicy.reason)
        switch action {
        case .registerAndEnable:
            // Reassert the existing socket/session; never run a second UDP reader.
            endpoint.reRegister(); endpoint.startLiveView()
        case .repairPresentation:
            decoder.prepareAfterForeground()
        case .repairDecoderAndEnable:
            decoder.flushForRecovery(); _=decoder.rebuildPresentation()
            endpoint.reRegister(); endpoint.startLiveView()
        case .rebuildSharedTransport:
            onControlTransportReset?()
            pose=nil; lastControlFrameAt=nil; lastCompleteAccessUnitAt=nil
            let epoch=connectionEpoch
            videoRecoveryTask=Task { [weak self] in
                do {
                    try await endpoint.rebuildUDP(reason:"headlink_bounded_video_repair")
                    try Task.checkCancellation()
                    guard let self,self.connectionEpoch == epoch,self.link === endpoint else { return }
                    connectionEpoch &+= 1
                    decoder.flushForRecovery(); endpoint.reRegister(); endpoint.startLiveView()
                    onVideoEvent?("shared_transport_repaired","new_epoch=\(connectionEpoch); motion_remains_paused")
                    videoRecoveryTask=nil; videoTimeoutTask?.cancel(); videoTimeoutTask=nil
                } catch {
                    guard let self,self.connectionEpoch == epoch,self.link === endpoint else { return }
                    videoPolicy.fail("shared_transport_repair_failed")
                    onVideoEvent?("shared_transport_failed",String(describing:error))
                    videoRecoveryTask=nil; videoTimeoutTask?.cancel(); videoTimeoutTask=nil
                    let evidence=healthEvidence()
                    if !endpoint.isFlowHealthy,!evidence.controlFresh,!evidence.videoFresh { disconnect(reason:"shared_transport_repair_failed") }
                }
            }
            videoTimeoutTask=Task { [weak self] in
                do { try await Task.sleep(for:.seconds(10)) } catch { return }
                guard let self,self.connectionEpoch == epoch,self.link === endpoint,self.videoRecoveryTask != nil else { return }
                let evidence=healthEvidence()
                if evidence.controlFresh || evidence.videoFresh {
                    onVideoEvent?("shared_transport_slow_ingress_alive","10s; no forced disconnect while data arrives")
                    return
                }
                videoPolicy.fail("shared_transport_repair_timeout_10s")
                onVideoEvent?("shared_transport_timeout","10s; no automatic camera re-pairing")
                disconnect(reason:"shared_transport_repair_timeout_10s")
            }
        }
    }
    func retryVideoRecovery() {
        guard connected,videoRecoveryTask == nil else { return }
        videoPolicy = .init(); videoCheckAt=0
        onVideoEvent?("video_retry_requested","user_action")
        checkVideoHealth()
    }
}
struct VideoDiagnostic:Codable {
    let sample:VideoPipelineSample; let recoveryState:String; let recoveryReason:String; let attempts:Int
    let packetCount:Int?; let accessUnits:Int?; let receiveErrors:Int?
    let decodeSubmitted:Int; let decodeAccepted:Int; let decodeOutputs:Int; let lastAcceptedSampleAt:Double?
    let presentationObservation:String
    let queueFrames:Int?; let queueBytes:Int?; let queueOldestMs:Double?; let incompleteAccessUnits:Int?; let dropped:Int?
    let socketGeneration:Int?; let registrationSubmissions:Int?; let lastRegistrationAge:Double?
    let sharedTransportRepairRunning:Bool; let lastControlFrameAt:Double?; let controlReceiveFresh:Bool; let transportHealthy:Bool
}
