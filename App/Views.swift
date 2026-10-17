import SwiftUI
import UIKit
import AVFoundation
import QuartzCore
import HeadLinkCore
import OpenCineApple

private let accent=Color(red:0.388,green:0.851,blue:0.929)
private let panel=Color(red:0.09,green:0.106,blue:0.129)
private let backdrop=Color(red:0.043,green:0.051,blue:0.063)

struct RootView: View {
    @Bindable var model: AppModel
    @State private var shooting=false
    @State private var settings=false
    @State private var resume=false
    @AppStorage("onboarded") private var onboarded=false
    @AppStorage("crosshair") private var crosshair=true
    @AppStorage("leftHanded") private var leftHanded=false
    @AppStorage("keepAwake") private var keepAwake=false
    @State private var diagnostics=false
    var body: some View {
        let _=model.controlRevision
        NavigationStack {
            GeometryReader { geo in
                ScrollView {
                    VStack(spacing:18) {
                        if !onboarded {
                            VStack(alignment:.leading,spacing:12) {
                                Text("让镜头跟随你的头部方向").font(.title2.bold())
                                Text("① 连接耳机与相机\n② 看向正前方并校准\n③ 点击开始，随时暂停")
                                Button("知道了") { onboarded=true }.buttonStyle(.bordered)
                            }.frame(maxWidth:.infinity,alignment:.leading).padding().background(panel,in:RoundedRectangle(cornerRadius:16))
                        }
                        if shooting {
                            statusBar
                            if geo.size.width > geo.size.height {
                                HStack(spacing:16) {
                                    if leftHanded { controls.frame(width:200) }
                                    preview.frame(minHeight:220)
                                    if !leftHanded { controls.frame(width:200) }
                                }
                            } else { preview.frame(minHeight:250); controls }
                            DisclosureGroup("精度与诊断",isExpanded:$diagnostics) { DiagnosticsPanel(model:model) }
                        } else { connection }
                        if let notice=model.notice { Label(LocalizedStringKey(notice),systemImage:"info.circle").font(.footnote).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading) }
                        Text(model.mountMode == .fixed ? "机身竖直固定 · 重力水平参考 · 倍率1.00" : "移动机身补偿未验证，跟随不可启动").font(.caption).foregroundStyle(.secondary)
                    }.padding(16)
                }.background(backdrop)
            }
            .navigationTitle("HeadLink")
            .toolbar {
                ToolbarItem(placement:.topBarLeading) { if shooting { Button("设备") { shooting=false } } }
                ToolbarItem(placement:.topBarTrailing) { Button("设置",systemImage:"gearshape") { settings=true } }
                ToolbarItem(placement:.bottomBar) {
                    if model.isFollowing { Button("暂停跟随",systemImage:"pause.fill") { model.pause() }.buttonStyle(.borderedProminent).tint(accent).accessibilityIdentifier("alwaysPause") }
                }
            }
            .sheet(isPresented:$settings) { SettingsView(model:model) }
            .sheet(isPresented:$model.showingCommissioning) { CommissioningView(model:model) }
            .sheet(isPresented:$model.showingCalibration,onDismiss:{
                if model.controller.state == .calibrating { model.clearCalibration() }
            }) {
                VStack(spacing:24) {
                    Image(systemName:"viewfinder").font(.system(size:56)).foregroundStyle(accent).accessibilityHidden(true)
                    Text("看向你想设定的正前方，并让镜头对准同一方向。").font(.title2).multilineTextAlignment(.center)
                    Text(model.controller.state == .calibrating ? "正在检查稳定性，请保持头部和机身静止" : "准备好后，建立新的方向对应关系")
                    Text("此操作不会发送机械回中指令").font(.footnote).foregroundStyle(.secondary)
                    if model.controller.state == .calibrating { ProgressView() }
                    else { Button("开始校准") { model.calibrate() }.buttonStyle(.borderedProminent).disabled(!model.canCalibrate) }
                    Button("取消") { model.clearCalibration(); model.showingCalibration=false }
                }.padding(28).presentationDetents([.medium,.large])
            }
            .confirmationDialog("恢复跟随",isPresented:$resume,titleVisibility:.visible) {
                Button("继续原对应关系") { model.start() }
                Button("以当前姿势重新对齐") { model.pause(); model.showingCalibration=true }
                Button("取消",role:.cancel) {}
            } message: { Text("继续原关系会以受限速度过渡到当前目标；重新对齐会保留当前构图。") }
            .onChange(of:shooting) { _,value in UIApplication.shared.isIdleTimerDisabled=value && keepAwake }
            .onChange(of:model.camera.connected) { _,value in if value { shooting=true } }
            .onChange(of:keepAwake) { _,value in UIApplication.shared.isIdleTimerDisabled=value && shooting }
            .tint(accent)
        }
    }
    private var connection: some View {
        VStack(spacing:18) {
            Text("头部联动拍摄").font(.title3).foregroundStyle(.secondary)
            card("耳机运动数据",icon:"airpodspro") {
                Text(LocalizedStringKey(model.motionLabel))
                HeadMotionReadout(model:model)
                Button("跟随状态与诊断") { model.pause(); model.showingCommissioning=true }.buttonStyle(.bordered)
                Text("先在 iPhone 系统中连接 AirPods。只有收到新鲜姿态，才表示运动数据可用。").font(.footnote).foregroundStyle(.secondary)
                Button("检查运动数据") { model.retryMotion() }.buttonStyle(.bordered)
                if model.motion.authorization == .denied { settingsLink }
            }
            card("Pocket 相机",icon:"camera") {
                Text(LocalizedStringKey(model.camera.message))
                if let camera=model.camera.selected { Text(camera.model.name).font(.headline) }
                if let fw=model.camera.status.firmware { Text("固件：\(fw)").font(.caption) }
                ForEach(model.camera.sightings) { sighting in
                    Button(sighting.name) { model.controller.connecting(); model.camera.connect(sighting) }.buttonStyle(.bordered)
                }
                if let request=model.camera.wifiRequest {
                    Text("打开系统“设置 → Wi-Fi”，加入下方网络，然后返回此处验证连接。").font(.footnote)
                    Text(request.ssid).font(.body.monospaced()).privacySensitive()
                    // Credentials enter the clipboard only after an explicit user copy action.
                    SecureCredential(password:request.password)
                    Button("已加入 Wi-Fi，验证连接") { model.camera.confirmWiFi() }.buttonStyle(.borderedProminent)
                } else {
                    HStack {
                        Button("搜索相机") { model.camera.scan() }.buttonStyle(.bordered)
                        Button("断开") { model.camera.disconnect() }.buttonStyle(.bordered)
                    }
                }
                Text("配对时请在相机屏幕确认。关闭 DJI Mimo，避免占用连接。").font(.footnote).foregroundStyle(.secondary)
            }
            Button("进入拍摄",systemImage:"viewfinder") { shooting=true }.frame(maxWidth:.infinity,minHeight:44).buttonStyle(.borderedProminent)
            Text("连接后：看向正前方、让镜头对准目标方向 → 校准 → 开始。无需重复首次实验。").font(.footnote).foregroundStyle(.orange)
        }
    }
    private var statusBar: some View {
        VStack(alignment:.leading,spacing:6) {
            HStack { Label(LocalizedStringKey(model.motionLabel),systemImage:"airpodspro"); Spacer(); Label(model.camera.connected ? (model.camera.controlReceiveFresh ? "相机控制有回报" : "相机会话在，控制回报过期") : "相机未连接",systemImage:"camera") }.font(.caption)
            Text(LocalizedStringKey(stateLabel(model.controller.state))).font(.headline).foregroundStyle(model.isFollowing ? accent : .primary)
        }
    }
    private var preview: some View {
        ZStack {
            Color.black
            if model.camera.connected { PreviewSurface(runtime:model.camera.decoder).aspectRatio(model.camera.decoder.pictureAspect,contentMode:.fit) }
            if !model.camera.previewLive {
                VStack(spacing:12) {
                    Image(systemName:"video.slash").font(.largeTitle)
                    Text(model.camera.lastPresentedAt == nil ? "等待真实相机预览" : "画面已暂停 · 最后一帧")
                    Text(LocalizedStringKey(model.camera.videoMessage)).font(.footnote)
                }.padding().background(.black.opacity(0.75),in:RoundedRectangle(cornerRadius:12))
            }
            if crosshair { Image(systemName:"plus").font(.body.weight(.ultraLight)).foregroundStyle(.white.opacity(0.6)).accessibilityHidden(true) }
            VStack {
                HStack {
                    if model.camera.actualRecording == true { Label("REC \(model.camera.status.recordElapsedSec)s",systemImage:"record.circle.fill").foregroundStyle(.red).monospacedDigit() }
                    else if model.camera.recordPending != nil { Text("等待录像确认…").foregroundStyle(.orange) }
                    Spacer()
                    LiveRangeIndicator(model:model)
                }.font(.caption.bold()).padding(12).background(.black.opacity(0.5))
                Spacer()
            }
        }.clipShape(RoundedRectangle(cornerRadius:14))
    }
    private var controls: some View {
        VStack(spacing:14) {
            Text(model.axes == .both ? "左右＋上下 1∶1" : model.axes == .yaw ? "仅左右 1∶1" : "仅上下 1∶1").font(.headline)
            Button("跟随状态与诊断",systemImage:"waveform.path") { model.pause(); model.showingCommissioning=true }.buttonStyle(.bordered)
            if !model.profileReady { Text("等待匹配真实机型的正式协议配置").font(.footnote).foregroundStyle(.orange) }
            if model.profileReady,let limits=model.controller.limits {
                Text("正式方向跟随 · 协议可达范围").font(.caption)
                Text(String(format:"机身坐标 yaw %.1f…%.1f° / pitch %.1f…%.1f°",limits.yawMin,limits.yawMax,limits.pitchMin,limits.pitchMax)).font(.caption).monospacedDigit()
            }
            if model.profileReady && !model.controller.hasCalibration {
                Text("看向正前方，让镜头对准对应方向，点击校准后开始。").font(.footnote).foregroundStyle(.orange)
            }
            Text(model.isFollowing ? "目标随头部更新，保持姿势即保持目标" : "校准成功后请明确点击开始跟随").font(.caption).foregroundStyle(.secondary)
            Button(model.isFollowing ? "暂停跟随" : "开始／恢复跟随",systemImage:model.isFollowing ? "pause.fill" : "play.fill") {
                if model.isFollowing { model.pause() }
                else if model.controller.state == .userPaused { resume=true }
                else { model.start() }
            }.buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth:.infinity,minHeight:52)
                .disabled(!model.isFollowing && !model.canStart).accessibilityIdentifier("followToggle")
            HStack {
                Button("校准",systemImage:"scope") { model.pause(); model.showingCalibration=true }.disabled(!model.canCalibrate)
                Spacer()
                Button(model.camera.actualRecording == true ? "停止录像" : "录像",systemImage:"record.circle") { model.camera.toggleRecording() }
                    .tint(.red).disabled(model.camera.actualRecording == nil || model.camera.recordPending != nil)
            }.buttonStyle(.bordered).frame(minHeight:44)
            if !model.isFollowing && !model.canStart {
                ForEach(Array(model.blockers.prefix(3)),id:\.self) { Text(LocalizedStringKey($0)).font(.footnote).foregroundStyle(.orange) }
            }
            if let error=model.camera.recordError { Text(LocalizedStringKey(error)).font(.footnote).foregroundStyle(.orange) }
        }
    }
    private func card<Content:View>(_ title:String,icon:String,@ViewBuilder content:()->Content) -> some View {
        VStack(alignment:.leading,spacing:12) { Label(LocalizedStringKey(title),systemImage:icon).font(.headline); content() }
            .frame(maxWidth:.infinity,alignment:.leading).padding(18).background(panel,in:RoundedRectangle(cornerRadius:16))
    }
    private func format(_ a:Angles?) -> String { a.map{String(format:"%.1f° / %.1f°",$0.yaw,$0.pitch)} ?? "不可用" }
    private var settingsLink: some View { Button("打开应用设置") { if let url=URL(string:UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } } }
}

private struct DiagnosticsPanel:View {
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
                .disabled(!model.camera.connected)
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
        Label("不可达：已限位，未缩放倍率",systemImage:"exclamationmark.triangle.fill")
            .foregroundStyle(.orange).opacity(model.controller.output?.limitedByRange == true ? 1 : 0)
            .accessibilityHidden(model.controller.output?.limitedByRange != true)
    }
}
private struct SecureCredential: View {
    let password:String
    @State private var reveal=false
    @State private var copied=false
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {
                Button(reveal ? "隐藏 Wi-Fi 密码" : "显示 Wi-Fi 密码") { reveal.toggle() }
                Spacer()
                Button {
                    UIPasteboard.general.setItems([["public.utf8-plain-text":password]],options:[.localOnly:true])
                    copied=true
                } label: {
                    Label(copied ? "密码已复制" : "复制密码",systemImage:copied ? "checkmark" : "doc.on.doc")
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
    case .userPaused:return "跟随已暂停"
    case .stalePaused:return "数据失效，已暂停"
    case .deviceDisconnected:return "设备断连"
    case .fault:return "姿态异常，请重新校准"
    }
}
