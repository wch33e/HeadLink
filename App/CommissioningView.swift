import SwiftUI
import HeadLinkCore

struct CommissioningView:View {
    @Bindable var model:AppModel
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        NavigationStack {
            ReadinessForm(model:model)
                .toolbar { Button("完成") { dismiss() } }
        }.presentationDragIndicator(.visible).presentationCornerRadius(HeadLinkUI.radius)
    }
}

/// Same model and actions as the original sheet; also presented by the More navigation stack.
struct ReadinessForm:View {
    @Bindable var model:AppModel
    var body:some View {
        let _=model.controlRevision
        let _=model.telemetryRevision
            Form {
                Section("正式1∶1方向跟随") {
                    Text("连接 → 校准 → 开始。倍率始终1.00，头部保持姿势即保持目标；回到基准即回到对应方向。")
                    Picker("安装方式",selection:$model.mountMode) {
                        ForEach(MountMode.allCases,id:\.self) { Text(LocalizedStringKey($0.title)).tag($0) }
                    }
                    Text("本版请将Pocket机身竖直固定，云台自由活动；不支持倾斜安装的世界坐标转换。固定模式不补偿支架转动。移动机身需要独立机身姿态和安装外参，不能从云台关节角反推身体朝向；移动模式未验证，不允许以固定映射运动。")
                }
                Section("耳机真实输入") {
                    LabeledContent("状态",value:model.motionLabel)
                    LabeledContent("数据时效",value:model.headAge.map{String(format:"%.0f ms",$0*1000)} ?? "未收到")
                    LabeledContent("回调频率",value:String(format:"%.1f Hz",model.callbackHz))
                    LabeledContent("重力水平参考",value:model.gravityAvailable ? "可用" : "不可用或接近竖直")
                    LabeledContent("校准后 yaw / pitch",value:angles(model.controller.head))
                    Button("重新检查耳机运动服务") { model.retryMotion() }.disabled(model.isFollowing)
                    Text("无需再次完成左右、上下小角度观察或实验确认。侧歪头不控制roll。")
                }
                Section("相机真实回报") {
                    LabeledContent("识别型号",value:model.camera.selected?.model.name ?? "未识别")
                    LabeledContent("回报固件",value:model.camera.status.firmware ?? "未上报，不推测")
                    LabeledContent("Osmo Pocket 4历史人工固件",value:"01.03.14.04（历史证据，不代表本次读取）")
                    LabeledContent("云台模式",value:model.camera.modeSummary)
                    LabeledContent("姿态 yaw / pitch",value:angles(model.camera.freshPose?.angles))
                    LabeledContent("原生 pitch",value:model.camera.freshPose.map{String(format:"%.1f°",$0.nativePitch)} ?? "不可用")
                    Button("读取模式参数") { model.camera.refreshControlInfo() }
                    Text("在机身顶部下滑选择Follow，关闭ActiveTrack与智能云台。Follow保留画面水平；FPV与俯仰锁定不能用于当前双轴跟随。App只核对真实回报，不擅自切换模式。")
                }
                Section("范围、实际响应与诊断") {
                    if let limits=model.formalLimits {
                        Text(String(format:"协议机身坐标范围：yaw %.1f…%.1f°；pitch %.1f…%.1f°",limits.yawMin,limits.yawMax,limits.pitchMin,limits.pitchMax))
                    }
                    Text("已移除个人±5°实验窗口。这里是固定上游协议可达范围，不是DJI规格表的同号坐标，也不代表这台相机的大角度光学精度已经测量。硬件和协议路径限制继续生效，不缩放倍率或自动重设基准。")
                    Text(LocalizedStringKey(model.feedbackSummary))
                    LabeledContent("目标角度",value:angles(model.camera.lastSubmittedAngles))
                    LabeledContent("网络写入数",value:"\(model.camera.nativeWrites)")
                    Text("核对值来自相机姿态反馈，2.5°只是异常暂停阈值，不是达到该物理精度的声明。外部量角精度、端到端延迟和漂移未测量。")
                    ForEach(model.blockers,id:\.self) { Text(LocalizedStringKey($0)).font(.footnote).foregroundStyle(.orange) }
                    if let invalidation=model.controller.invalidation {
                        Text("历史校准失效：\(invalidation.reason.message)").font(.footnote).foregroundStyle(.secondary)
                    }
                    Button("生成脱敏诊断文件") { model.exportDiagnostics() }
                    if let url=model.exportURL { ShareLink("分享 JSON",item:url) }
                }
            }
        .headLinkList().navigationTitle("跟随状态与诊断").navigationBarTitleDisplayMode(.inline)
    }
    private func angles(_ a:Angles?) -> String { a.map{String(format:"%.1f° / %.1f°",$0.yaw,$0.pitch)} ?? "不可用" }
}
