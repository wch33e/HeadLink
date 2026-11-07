import SwiftUI
import HeadLinkCore

struct CurrentShootingStatus:View {
    @Bindable var model:AppModel
    var body:some View {
        let _=model.controlRevision
        Text(LocalizedStringKey(model.shortShootingStatus)).font(.caption.weight(.medium))
            .foregroundStyle(model.rangeLimited ? HeadLinkUI.accent : .primary)
            .lineLimit(2).accessibilityIdentifier("trackingState")
    }
}
struct ShootingDetailsSheet:View {
    @Bindable var model:AppModel
    @Binding var detent:PresentationDetent
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicType
    var body:some View {
        let _=model.controlRevision
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    CurrentShootingStatus(model:model)
                    Button(detent == .large ? "收起详情" : "展开详情") { detent=detent == .large ? .height(180) : .large }
                        .accessibilityIdentifier("toggleDetails").frame(minHeight:44)
                    #if DEBUG
                    DebugPresentationProbe(model:model)
                    if DebugFlowFixture.current != nil {
                        Text(detent == .large ? "expanded" : "compact").accessibilityIdentifier("fixtureDetent")
                    }
                    #endif
                    DisclosureGroup("当前条件与范围") {
                        ForEach(model.startIssues) { Text(LocalizedStringKey($0.message)).font(.footnote) }
                        RangeDetails(model:model)
                        Text(LocalizedStringKey(model.camera.videoMessage)).font(.footnote)
                        if let reason=model.camera.recordBlocker { Text(LocalizedStringKey(reason)).font(.footnote) }
                        if let error=model.camera.recordError { Text(LocalizedStringKey(error)).font(.footnote).foregroundStyle(.red) }
                    }.accessibilityIdentifier("rangeDetails")
                    DisclosureGroup("操作说明") {
                        if model.isMobile {
                            Text("机身设为 Follow，关闭 ActiveTrack 和智能跟随。头部转动拨动镜头，头停后交给相机稳定；机身旋转和走路的平移没有世界坐标补偿。居中只更新头部参考，不命令云台回机械中心。")
                        }
                        Text("连接 → 校准 → 明确开始。头部保持姿势即保持目标，回到基准则镜头回到对应基准。暂停可随时操作，录像独立。")
                        Text("普通目标超限仅限制发送目标；倍率和原基准不变。不可达路径、真实输入失效或发送失败仍分别处理。")
                    }
                    DisclosureGroup("实时数值与诊断") { DiagnosticsPanel(model:model) }
                    if let notice=model.notice {
                        DisclosureGroup("历史操作与提示") { Text(LocalizedStringKey(notice)).font(.footnote) }
                    }
                }.frame(maxWidth:.infinity,alignment:.leading).padding(16)
            }.background(HeadLinkUI.canvas)
                .navigationTitle(model.camera.actualRecording == true ? "REC · 拍摄详情" : "拍摄详情").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement:.cancellationAction) {
                        if model.isFollowing { Button(dynamicType.isAccessibilitySize ? "暂停" : "暂停跟随") { model.pause() }.accessibilityLabel("暂停跟随").accessibilityIdentifier("detailsPause") }
                    }
                    ToolbarItem(placement:.confirmationAction) { Button("完成") { dismiss() }.accessibilityIdentifier("closeShootingDetails") }
                }
        }.headLinkTheme().presentationDetents([.height(180),.medium,.large],selection:$detent)
            .presentationDragIndicator(.visible).presentationCornerRadius(HeadLinkUI.radius)
    }
}
struct RangeDetails:View {
    @Bindable var model:AppModel
    var body:some View {
        let _=model.telemetryRevision
        if model.isMobile,let target=model.mobile.goal {
            Text(String(format:"移动目标 yaw %.1f° / pitch %.1f°",target.yaw,target.pitch)).monospacedDigit()
        } else if let output=model.controller.output {
            Text(String(format:"原始目标 yaw %.1f° / pitch %.1f°",output.raw.yaw,output.raw.pitch)).monospacedDigit()
            Text(String(format:"合法限位目标 yaw %.1f° / pitch %.1f°",output.limited.yaw,output.limited.pitch)).monospacedDigit()
        }
        if let limits=model.controller.limits {
            Text(String(format:"既有协议坐标范围 yaw %.1f…%.1f° / pitch %.1f…%.1f°",limits.yawMin,limits.yawMax,limits.pitchMin,limits.pitchMax)).monospacedDigit()
        }
        Text("目标限位不等于镜头已到位；实际回报、路径限制与传输拒绝在诊断中分别记录。").font(.caption).foregroundStyle(.secondary)
    }
}
