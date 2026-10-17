import SwiftUI
import UIKit
import AVFoundation
import QuartzCore
import HeadLinkCore
import OpenCineApple

private enum DeviceFocus { case camera, headphones }

struct RootView:View {
    @Bindable var model:AppModel
    @State private var shooting=false
    @State private var settings=false
    @State private var resume=false
    @State private var deviceFocus:DeviceFocus = .camera
    @Environment(\.dynamicTypeSize) private var dynamicType
    @AppStorage("onboarded") private var onboarded=false
    @AppStorage("crosshair") private var crosshair=true
    @AppStorage("leftHanded") private var leftHanded=false
    @AppStorage("keepAwake") private var keepAwake=false

    var body:some View {
        let _=model.controlRevision
        NavigationStack {
            ZStack {
                // One stable video subtree, including while device details cover the monitor.
                monitor.accessibilityHidden(!shooting).allowsHitTesting(shooting)
                if !shooting { devices }
            }
            .background(HeadLinkUI.canvas)
            .toolbar(.hidden,for:.navigationBar)
            .sheet(isPresented:$settings) { SettingsView(model:model) }
            .sheet(isPresented:$model.showingCommissioning) { CommissioningView(model:model) }
            .sheet(isPresented:$model.showingCalibration,onDismiss:{
                if model.controller.state == .calibrating { model.clearCalibration() }
            }) { CalibrationSheet(model:model) }
            .confirmationDialog("恢复跟随",isPresented:$resume,titleVisibility:.visible) {
                Button("继续原对应关系") { model.start() }
                Button("以当前姿势重新对齐") { model.pause(); model.showingCalibration=true }
                Button("取消",role:.cancel) {}
            } message: { Text("继续原关系会以受限速度过渡到当前目标；重新对齐会保留当前构图。") }
            .onChange(of:shooting) { _,value in UIApplication.shared.isIdleTimerDisabled=value && keepAwake }
            .onChange(of:model.camera.connected) { _,value in if value { shooting=true } }
            .onChange(of:keepAwake) { _,value in UIApplication.shared.isIdleTimerDisabled=value && shooting }
            .tint(HeadLinkUI.accent)
        }
    }

    private var monitor:some View {
        GeometryReader { geometry in
            ZStack {
                preview.frame(maxWidth:.infinity,maxHeight:.infinity)
                if dynamicType.isAccessibilitySize && geometry.size.width > geometry.size.height {
                    HStack(spacing:16) {
                        if leftHanded { accessibleControls.frame(width:min(280,geometry.size.width*0.4)) }
                        ScrollView {
                            VStack(spacing:12) { topBar; followState; recordingIndicators; messages(maxHeight:geometry.size.height) }
                        }
                        if !leftHanded { accessibleControls.frame(width:min(280,geometry.size.width*0.4)) }
                    }.padding(16)
                } else {
                    VStack(spacing:12) {
                        topBar
                        followState
                        recordingIndicators
                        Spacer(minLength:0)
                        VStack(spacing:12) {
                            messages(maxHeight:geometry.size.height > geometry.size.width ? 152 : 88)
                            controls
                        }
                    }.padding(.horizontal,HeadLinkUI.inset).padding(.vertical,8)
                }
            }.frame(width:geometry.size.width,height:geometry.size.height)
        }
    }
    private var followState:some View {
        HStack {
            Text(LocalizedStringKey(stateLabel(model.controller.state)))
                .font(.subheadline.weight(.medium)).padding(.horizontal,12).padding(.vertical,8)
                .background(.black.opacity(0.85),in:Capsule()).accessibilityIdentifier("trackingState")
            Spacer(minLength:0)
        }
    }
    private var cameraSummary:String {
        model.camera.connected ? (model.camera.controlReceiveFresh ? "相机控制有回报" : "相机会话在，控制回报过期") : "相机未连接"
    }

    private var topBar:some View {
        HStack(spacing:8) {
            Button { deviceFocus = .camera; shooting=false } label: {
                Label {
                    Text(dynamicType.isAccessibilitySize ? (model.camera.connected ? "已连" : "未连") : cameraSummary)
                        .font(.caption).multilineTextAlignment(.leading)
                } icon: { Image(systemName:"camera").font(.body) }
            }.accessibilityLabel(cameraSummary).accessibilityIdentifier("cameraDetails")
            Divider().frame(height:24).padding(.horizontal,4)
            Button { deviceFocus = .headphones; shooting=false } label: {
                Label(LocalizedStringKey(dynamicType.isAccessibilitySize ? "耳机" : model.motionLabel),systemImage:"airpodspro")
                    .font(.caption).multilineTextAlignment(.leading)
            }.accessibilityLabel(model.motionLabel).accessibilityIdentifier("headphoneDetails")
            Spacer(minLength:0)
            Button { settings=true } label: { Image(systemName:"ellipsis").font(.title3) }
                .accessibilityLabel("更多与设置").accessibilityIdentifier("openSettings")
        }
        .buttonStyle(QuietButtonStyle()).foregroundStyle(.primary)
        .padding(.horizontal,12).padding(.vertical,4).floatingSurface()
    }

    private var preview:some View {
        ZStack {
            Color.black
            if model.camera.connected {
                PreviewSurface(runtime:model.camera.decoder).aspectRatio(model.camera.decoder.pictureAspect,contentMode:.fit)
            }
            if !model.camera.previewLive {
                VStack(spacing:12) {
                    Image(systemName:"video.slash").font(.title)
                    Text(model.camera.lastPresentedAt == nil ? "等待真实相机预览" : "画面已暂停 · 最后一帧").font(.callout)
                    Text(LocalizedStringKey(model.camera.videoMessage)).font(.footnote).foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center).padding(20)
                .background(.black.opacity(0.85),in:RoundedRectangle(cornerRadius:20))
            }
            if crosshair {
                Image(systemName:"plus").font(.body.weight(.ultraLight)).foregroundStyle(.white.opacity(0.6)).accessibilityHidden(true)
            }
        }
    }
    private var recordingIndicators:some View {
        HStack(alignment:.top) {
            VStack(alignment:.leading,spacing:8) {
                if model.camera.actualRecording == true || model.camera.recordPending != nil {
                    Group {
                        if model.camera.actualRecording == true {
                            Label("REC \(model.camera.status.recordElapsedSec)s",systemImage:"record.circle.fill")
                                .foregroundStyle(.red).monospacedDigit()
                        } else { Text("等待录像确认…").foregroundStyle(.orange) }
                    }.padding(8).background(.black.opacity(0.75),in:RoundedRectangle(cornerRadius:12))
                }
                LiveRangeIndicator(model:model)
            }.font(.caption.weight(.medium))
            Spacer(minLength:0)
        }.allowsHitTesting(false)
    }

    @ViewBuilder private func messages(maxHeight:CGFloat) -> some View {
        if model.notice != nil || model.camera.recordError != nil || (!model.isFollowing && !model.canStart) {
            ScrollView {
                VStack(alignment:.leading,spacing:8) {
                    if let notice=model.notice {
                        Label(LocalizedStringKey(notice),systemImage:"info.circle")
                    }
                    if !model.isFollowing && !model.canStart {
                        ForEach(Array(model.blockers.prefix(3)),id:\.self) {
                            Label(LocalizedStringKey($0),systemImage:"exclamationmark.circle").foregroundStyle(.orange)
                        }
                    }
                    if let error=model.camera.recordError {
                        Label(LocalizedStringKey(error),systemImage:"record.circle").foregroundStyle(.orange)
                    }
                }.font(.footnote).frame(maxWidth:.infinity,alignment:.leading).padding(12)
            }
            .frame(maxHeight:maxHeight)
            .fixedSize(horizontal:false,vertical:true)
            .background(.black.opacity(0.9),in:RoundedRectangle(cornerRadius:16))
        }
    }

    private var controls:some View {
        HStack(spacing:8) {
            if leftHanded { recordButton; followButton; calibrateButton }
            else { calibrateButton; followButton; recordButton }
        }
        .padding(8).floatingSurface()
    }
    private var accessibleControls:some View {
        VStack(spacing:8) {
            followButton
            HStack(spacing:8) {
                if leftHanded { recordButton; calibrateButton }
                else { calibrateButton; recordButton }
            }
        }.padding(8).floatingSurface()
    }
    private var calibrateButton:some View {
        Button { model.pause(); model.showingCalibration=true } label: {
            VStack(spacing:4) { Image(systemName:"scope").font(.title3); Text("校准").font(.caption) }
                .frame(minWidth:52,minHeight:52).padding(.horizontal,4)
        }
        .buttonStyle(QuietButtonStyle()).disabled(!model.canCalibrate).accessibilityIdentifier("calibrate")
    }
    private var followButton:some View {
        Button {
            if model.isFollowing { model.pause() }
            else if model.controller.state == .userPaused { resume=true }
            else { model.start() }
        } label: {
            Label(dynamicType.isAccessibilitySize ? (model.isFollowing ? "暂停" : (model.controller.state == .userPaused ? "恢复" : "开始")) : (model.isFollowing ? "暂停跟随" : "开始／恢复跟随"),systemImage:model.isFollowing ? "pause.fill" : "play.fill")
                .font(.callout.weight(.semibold)).multilineTextAlignment(.center)
                .frame(maxWidth:.infinity,minHeight:44).padding(.vertical,4)
        }
        .buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius:18))
        .tint(HeadLinkUI.accent).foregroundStyle(model.isFollowing || model.canStart ? Color.black : Color.primary)
        .disabled(!model.isFollowing && !model.canStart)
        .accessibilityLabel(model.isFollowing ? "暂停跟随" : "开始／恢复跟随")
        .accessibilityIdentifier(model.isFollowing ? "alwaysPause" : "followToggle")
    }
    private var recordButton:some View {
        Button { model.camera.toggleRecording() } label: {
            VStack(spacing:4) {
                Image(systemName:model.camera.actualRecording == true ? "stop.circle" : "record.circle").font(.title3)
                Text(model.camera.actualRecording == true ? "停止录像" : "录像").font(.caption).foregroundStyle(.primary)
            }.frame(minWidth:52,minHeight:52).padding(.horizontal,4)
        }
        .buttonStyle(QuietButtonStyle()).foregroundStyle(.red)
        .disabled(model.camera.actualRecording == nil || model.camera.recordPending != nil)
        .accessibilityIdentifier("recordToggle")
    }

    private var devices:some View {
        VStack(spacing:0) {
            HStack {
                Button { shooting=true } label: { Label("监看",systemImage:"chevron.left") }
                    .accessibilityIdentifier("enterMonitor")
                Spacer()
                Text("设备").font(.headline)
                Spacer()
                Button { settings=true } label: { Image(systemName:"ellipsis") }
                    .accessibilityLabel("更多与设置").accessibilityIdentifier("deviceSettings")
            }.buttonStyle(QuietButtonStyle()).padding(.horizontal,16).padding(.vertical,4)
            Form {
                if !onboarded {
                    Section {
                        Text("① 连接耳机与相机\n② 看向正前方并校准\n③ 点击开始，随时暂停").font(.callout)
                        Button("知道了") { onboarded=true }.accessibilityIdentifier("dismissOnboarding")
                    }
                }
                if deviceFocus == .headphones { headphones; camera }
                else { camera; headphones }
                Section {
                    Button("进入拍摄",systemImage:"viewfinder") { shooting=true }.frame(minHeight:44)
                        .accessibilityIdentifier("enterShooting")
                } footer: {
                    Text("连接后：看向正前方、让镜头对准目标方向 → 校准 → 开始。无需重复首次实验。")
                }
                if let notice=model.notice { Section { Text(LocalizedStringKey(notice)).font(.footnote) } }
                Section {
                    Text(model.mountMode == .fixed ? "机身竖直固定 · 重力水平参考 · 倍率1.00" : "移动机身补偿未验证，跟随不可启动").font(.footnote).foregroundStyle(.secondary)
                }
            }.headLinkList()
        }
        .background(Color(uiColor:.systemGroupedBackground))
    }
    private var camera:some View {
        Section {
            LabeledContent("状态",value:model.camera.message)
            if let camera=model.camera.selected { LabeledContent("型号",value:camera.model.name) }
            if let firmware=model.camera.status.firmware { LabeledContent("固件",value:firmware) }
            ForEach(model.camera.sightings) { sighting in
                Button(sighting.name) { model.controller.connecting(); model.camera.connect(sighting) }.frame(minHeight:44)
            }
            if let request=model.camera.wifiRequest {
                Text("打开系统“设置 → Wi-Fi”，加入下方网络，然后返回此处验证连接。").font(.footnote)
                Text(request.ssid).font(.body.monospaced()).privacySensitive()
                SecureCredential(password:request.password)
                Button("已加入 Wi-Fi，验证连接") { model.camera.confirmWiFi() }.frame(minHeight:44)
            } else {
                Button("搜索相机",systemImage:"magnifyingglass") { model.camera.scan() }.frame(minHeight:44)
                Button("断开",systemImage:"link") { model.camera.disconnect() }.frame(minHeight:44)
            }
        } header: { Label("Pocket 相机",systemImage:"camera") }
        footer: { Text("配对时请在相机屏幕确认。关闭 DJI Mimo，避免占用连接。") }
    }
    private var headphones:some View {
        Section {
            LabeledContent("状态",value:model.motionLabel)
            HeadMotionReadout(model:model)
            Button("检查运动数据",systemImage:"waveform") { model.retryMotion() }.frame(minHeight:44)
            Button("跟随状态与诊断",systemImage:"waveform.path") { model.pause(); model.showingCommissioning=true }.frame(minHeight:44)
            if model.motion.authorization == .denied {
                Button("打开应用设置") {
                    if let url=URL(string:UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }.frame(minHeight:44)
            }
        } header: { Label("耳机运动数据",systemImage:"airpodspro") }
        footer: { Text("先在 iPhone 系统中连接 AirPods。只有收到新鲜姿态，才表示运动数据可用。") }
    }
}

private struct CalibrationSheet:View {
    @Bindable var model:AppModel
    var body:some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:24) {
                    Image(systemName:"scope").font(.largeTitle).foregroundStyle(HeadLinkUI.accent).accessibilityHidden(true)
                    Text("看向你想设定的正前方，并让镜头对准同一方向。").font(.title2.weight(.medium))
                    Text(model.controller.state == .calibrating ? "正在检查稳定性，请保持头部和机身静止" : "准备好后，建立新的方向对应关系").font(.body)
                    Text("此操作不会发送机械回中指令").font(.footnote).foregroundStyle(.secondary)
                    if let notice=model.notice { Text(LocalizedStringKey(notice)).font(.footnote).foregroundStyle(.secondary) }
                    if model.controller.state == .calibrating { ProgressView() }
                    else {
                        Button("开始校准") { model.calibrate() }.buttonStyle(.borderedProminent)
                            .controlSize(.large).disabled(!model.canCalibrate)
                    }
                    Button("取消") { model.clearCalibration(); model.showingCalibration=false }.frame(minHeight:44)
                }.frame(maxWidth:.infinity,alignment:.leading).padding(24)
            }.navigationTitle("校准").navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium,.large]).presentationDragIndicator(.visible)
        .presentationCornerRadius(HeadLinkUI.radius)
    }
}

struct DiagnosticsPanel:View {
    @Bindable var model:AppModel
    var body:some View {
        let _=model.telemetryRevision
        VStack(spacing:10) {
            metric("观察头部方向（未校准也可看）",format((model.headAge.map{$0 <= 0.2} ?? false) ? model.probe.look : nil))
            metric("校准后头部方向",format(model.controller.head))
            metric("未裁剪目标",format(model.controller.rawTarget))
            metric("命令目标（已提交）",format(model.controller.output?.command))
            metric("镜头反馈（机身参考）",format(model.camera.freshPose?.angles))
            if let base=model.controller.calibrationCameraPose?.angles,let actual=model.camera.freshPose?.angles {
                metric("镜头相对校准方向",format(.init(yaw:actual.yaw-base.yaw,pitch:actual.pitch-base.pitch)))
            }
            Text(LocalizedStringKey(model.feedbackSummary))
            Text("相机回报核对不是外部光学精度测量").font(.caption).foregroundStyle(.secondary)
            metric("运动数据时效",model.headAge.map{String(format:"%.0f ms",$0*1000)} ?? "不可用")
            metric("实际回调频率",String(format:"%.1f Hz",model.callbackHz))
            metric("实际网络写入频率",String(format:"%.1f Hz",model.sendHz))
            metric("完整端到端延迟","不可用：需要外部同步测量")
            if !model.blockers.isEmpty { ForEach(model.blockers,id:\.self) { Text(LocalizedStringKey($0)).foregroundStyle(.orange) } }
            Text(LocalizedStringKey(model.camera.videoMessage))
            Button("重试图传恢复（不启动跟随）") { model.camera.retryVideoRecovery() }
                .disabled(!model.camera.connected).frame(minHeight:44)
            Text("命令提交或网络写入不等于镜头已到位。暂停命令尚无停止确认。").font(.caption).foregroundStyle(.secondary)
        }.padding(.top,12).font(.footnote).monospacedDigit()
    }
    private func metric(_ name:String,_ value:String) -> some View {
        HStack(alignment:.top) { Text(LocalizedStringKey(name)).foregroundStyle(.secondary); Spacer(); Text(LocalizedStringKey(value)).multilineTextAlignment(.trailing) }
    }
    private func format(_ a:Angles?) -> String { a.map{String(format:"%.1f° / %.1f°",$0.yaw,$0.pitch)} ?? "不可用" }
}
private struct HeadMotionReadout:View {
    @Bindable var model:AppModel
    var body:some View {
        let _=model.telemetryRevision
        let fresh=(model.headAge.map{$0 <= 0.2} ?? false) ? model.probe.look : nil
        Text("观察 yaw / pitch：\(fresh.map{String(format:"%.1f° / %.1f°",$0.yaw,$0.pitch)} ?? "不可用")").monospacedDigit()
        Text(String(format:"实际回调 %.1f Hz",model.callbackHz)).font(.caption)
    }
}
private struct LiveRangeIndicator:View {
    @Bindable var model:AppModel
    var body:some View {
        let _=model.telemetryRevision
        if model.controller.output?.limitedByRange == true {
            Label("不可达：已限位，未缩放倍率",systemImage:"exclamationmark.triangle.fill")
                .foregroundStyle(.orange).padding(8).background(.black.opacity(0.75),in:RoundedRectangle(cornerRadius:12))
        }
    }
}
private struct SecureCredential: View {
    let password:String
    @State private var reveal=false
    @State private var copied=false
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            VStack(alignment:.leading,spacing:8) {
                Button(reveal ? "隐藏 Wi-Fi 密码" : "显示 Wi-Fi 密码") { reveal.toggle() }.frame(minHeight:44)
                Button {
                    UIPasteboard.general.setItems([["public.utf8-plain-text":password]],options:[.localOnly:true])
                    copied=true
                } label: {
                    Label(copied ? "密码已复制" : "复制密码",systemImage:copied ? "checkmark" : "doc.on.doc").frame(minHeight:44)
                }.buttonStyle(.bordered).disabled(password.isEmpty)
            }
            if reveal { Text(password).font(.body.monospaced()).textSelection(.enabled).privacySensitive() }
        }.onChange(of:password) { _,_ in copied=false; reveal=false }
    }
}
struct PreviewSurface: UIViewRepresentable {
    let runtime:MonitorLiveVideoRuntime
    func makeUIView(context:Context) -> VideoContainer { let view=VideoContainer(); view.bind(runtime); return view }
    func updateUIView(_ view:VideoContainer,context:Context) { view.bind(runtime) }
}
final class VideoContainer: UIView {
    private weak var runtime:MonitorLiveVideoRuntime?
    private var display:AVSampleBufferDisplayLayer?
    func bind(_ next:MonitorLiveVideoRuntime) {
        guard runtime !== next || display !== next.displayLayer else { return }
        display?.removeFromSuperlayer(); runtime=next; display=next.displayLayer
        display?.videoGravity = .resizeAspect
        layer.addSublayer(next.displayLayer); setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if display?.frame != bounds { display?.frame=bounds }
        CATransaction.commit()
        runtime?.noteDisplayReady()
    }
}
func stateLabel(_ state:TrackingState) -> String {
    switch state {
    case .disconnected:return "未连接"
    case .connecting:return "连接中"
    case .waitingMotion:return "已连接，等待运动数据"
    case .ready:return "就绪，尚未校准"
    case .calibrating:return "校准中"
    case .calibrated:return "已校准，等待开始"
    case .following:return "跟随中"
    case .userPaused:return "用户暂停"
    case .stalePaused:return "数据失效，已暂停"
    case .deviceDisconnected:return "设备断连"
    case .fault:return "姿态异常，请重新校准"
    }
}
