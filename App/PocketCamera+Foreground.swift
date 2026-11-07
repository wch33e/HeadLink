import Foundation
import HeadLinkCore
import OpenCineDJI
import OpenCineDJIApple
import OpenCineApple

extension PocketCamera {
    func pauseForInactiveScene() {
        sceneActive=false
        if foregroundRecovery.running {
            foregroundRecovery.arm()
            disconnect(reason:"inactive_during_foreground_recovery",preservingRecovery:true)
        }
    }
    func suspendForBackground() {
        sceneActive=false
        // The explicit manual Settings handoff owns a finite connection run already.
        // Do not cancel it and force the user through pairing a second time.
        if wifiRequest != nil { onSessionEvent?("background_wifi_handoff","preserving_pending_manual_join"); return }
        if connected,let selected,let sessionSSID { resumeTarget=(selected,sessionSSID) }
        foregroundRecovery.arm()
        disconnect(reason:"app_background",preservingRecovery:true)
    }
    func resumeAfterForeground() {
        let wasInactive = !sceneActive
        sceneActive=true
        if connected {
            if wasInactive {
                decoder.prepareAfterForeground()
                subscriptionAttempts=0; lastSubscriptionAttemptAt=nil
            }
            return
        }
        guard wifiRequest == nil,let target=resumeTarget else { return }
        network.start()
        foregroundRecovery.start(expectedSSID:target.ssid,actions:.init(
            pathReady:{ DjiAppleWiFiJoiner.isCameraPathReady() },
            openIdentity:{ [weak self] in
                guard let self else { throw CancellationError() }
                let model=target.sighting.model
                let endpoint=DjiAppleDatalink(port:UInt16(model.datalinkPort),tcpPoke:model.tcpPoke,pairingToken:model.pairingToken)
                link=endpoint; bindLink()
                try await endpoint.open(identityOnly:true,afterHandshake:nil)
            },readSSID:{ [weak self] in
                guard let self,let endpoint=link else { throw CancellationError() }
                let request=exchange.request(matching:[(7,7)],timeout:.seconds(4),consumeHold:false,
                    send:{ _=endpoint.send(Commands.getWifiSsid(id:0)) })
                defer { request.cancel() }
                return Duml.unpackStatusString(try await request.value().payload)
            },activate:{ [weak self] in
                guard let self,let endpoint=link,sceneActive else { return }
                selected=target.sighting; sessionSSID=target.ssid
                decoder=MonitorLiveVideoRuntime(); decoder.onPresentedFrame={ [weak self] in self?.lastPresentedAt=self?.now }
                bindLink(); endpoint.completeRegistration()
                connected=true; beginVideoSession(); endpoint.startLiveView()
                heartbeatStartAfterRecovery()
            },discard:{ [weak self] in self?.disconnect(reason:"foreground_recovery_failed",preservingRecovery:true) },
            event:{ [weak self] event in self?.reportForegroundRecovery(event) }))
    }
    func retryOriginalConnection() {
        guard !connected,!foregroundRecovery.running else { return }
        foregroundRecovery.arm(); resumeAfterForeground()
    }
    private func reportForegroundRecovery(_ event:String) {
        onSessionEvent?("foreground_camera_recovery",event)
        switch event {
        case "checking_original_camera":recoveryMessage="正在核对原相机身份并恢复通信，跟随保持停止"
        case "restored_no_motion":recoveryMessage=allowMobileRecovery ? "原相机通信已恢复；确认预览后明确开始，不追赶过去动作" : "原相机通信已恢复，等待真实预览与状态；请校准后明确开始跟随"
        case "wifi_required":recoveryMessage="未检测到相机网段：请到系统设置→Wi-Fi 加入原相机网络，返回后点恢复原相机"
        case "wrong_camera":recoveryMessage="当前网络上的相机身份与原设备不一致；请加入原相机 Wi-Fi 后重试"
        default:recoveryMessage="原相机通信或身份核对未完成：请确认机身保持开机与连接状态、关闭 Mimo，并核对本地网络权限；点恢复原相机重试，必要时在机身确认连接"
        }
        if let recoveryMessage { message=recoveryMessage }
    }
}
