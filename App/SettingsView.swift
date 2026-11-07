import SwiftUI
import HeadLinkCore

struct SettingsView:View {
    @Bindable var model:AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var readiness=false
    var body:some View {
        NavigationStack {
            Form {
                #if DEBUG
                if DebugFlowFixture.current != nil { Section { DebugThemeLabel() }.listRowBackground(HeadLinkUI.group) }
                #endif
                Section { AppearancePicker() }.listRowBackground(HeadLinkUI.group)
                Section {
                    Picker("控制轴",selection:$model.axes) {
                        Text("左右＋上下").tag(ControlAxes.both); Text("仅左右").tag(ControlAxes.yaw); Text("仅上下").tag(ControlAxes.pitch)
                    }.accessibilityIdentifier("axesSetting")
                    if !model.isMobile { LabeledContent("倍率",value:"1.00") }
                    Picker("响应",selection:$model.response) {
                        Text("低延迟").tag(ResponseMode.immediate); Text("轻度平滑").tag(ResponseMode.smooth)
                    }.accessibilityIdentifier("responseSetting")
                    Picker("安装方式",selection:$model.mountMode) {
                        ForEach(MountMode.allCases,id:\.self) { Text(LocalizedStringKey($0.title)).tag($0) }
                    }.accessibilityIdentifier("mountSetting")
                } header: { Text("跟随") }
                footer: { Text("更改控制设置会暂停跟随；查看说明不影响控制。") }.listRowBackground(HeadLinkUI.group)
                Section { DisclosureGroup("参数与安装说明") {
                    Text("固定机身保留原1∶1方向关系。移动机身使用相对拨动；头停后由相机 Follow 接管。无独立机身姿态，不能锁定世界方向或消除平移。")
                    if model.isMobile {
                        Picker("移动灵敏度",selection:$model.mobileGain) {
                            Text("0.50×").tag(0.5); Text("0.75×").tag(0.75); Text("1.00×").tag(1.0)
                        }
                        Toggle("移动左右反向",isOn:$model.reverseMobileYaw)
                        Toggle("移动上下反向",isOn:$model.reverseMobilePitch)
                    }
                } }.listRowBackground(HeadLinkUI.group)
                Section {
                    Button {
                        readiness=true
                    } label: {
                        VStack(alignment:.leading,spacing:4) {
                            SettingTitle(title:"跟随状态与诊断",icon:"waveform.path")

                        }
                    }
                    .accessibilityIdentifier("openReadiness")
                    NavigationLink { LiveDiagnosticsView(model:model) } label: {
                        SettingTitle(title:"实时数值与图传",icon:"chart.xyaxis.line")
                    }.accessibilityIdentifier("openLiveDiagnostics")
                    Button("清除校准",systemImage:"scope") { model.clearCalibration() }
                }.listRowBackground(HeadLinkUI.group)
                Section {
                    NavigationLink { DisplaySettingsView() } label: { SettingTitle(title:"画面与反馈",icon:"viewfinder") }
                        .accessibilityIdentifier("openDisplaySettings")
                    NavigationLink { LocalDiagnosticsView(model:model) } label: { SettingTitle(title:"本地诊断",icon:"doc.text") }
                        .accessibilityIdentifier("openLocalDiagnostics")
                    NavigationLink { AboutHeadLinkView() } label: { SettingTitle(title:"关于 HeadLink",icon:"info.circle") }
                        .accessibilityIdentifier("openAbout")
                }.listRowBackground(HeadLinkUI.group)
            }
            .headLinkList().navigationTitle("更多").navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented:$readiness) { ReadinessForm(model:model) }
            .toolbar { ToolbarItem(placement:.confirmationAction) { Button("完成") { dismiss() }.accessibilityIdentifier("closeSettings") } }
        }
        .headLinkTheme().presentationDetents([.large]).presentationDragIndicator(.visible).presentationCornerRadius(HeadLinkUI.radius)
    }
}

private struct DisplaySettingsView:View {
    @AppStorage("crosshair") private var crosshair=true
    @AppStorage("leftHanded") private var leftHanded=false
    @AppStorage("keepAwake") private var keepAwake=false
    @AppStorage("haptics") private var haptics=false
    var body:some View {
        Form {
            Section {
                Toggle("十字线",isOn:$crosshair).accessibilityIdentifier("crosshairSetting")
                Toggle("左手布局",isOn:$leftHanded).accessibilityIdentifier("leftHandedSetting")
                Toggle("拍摄页保持常亮",isOn:$keepAwake).accessibilityIdentifier("keepAwakeSetting")
                Toggle("操作震动",isOn:$haptics).accessibilityIdentifier("hapticsSetting")
            }.listRowBackground(HeadLinkUI.group)
        }.headLinkList().navigationTitle("画面与反馈").navigationBarTitleDisplayMode(.inline)
    }
}

private struct LocalDiagnosticsView:View {
    @Bindable var model:AppModel
    @AppStorage("recordDiagnostics") private var recordDiagnostics=false
    var body:some View {
        Form {
            Section {
                Toggle("记录诊断",isOn:$recordDiagnostics)
            } footer: {
                Text("最多保留最近约10分钟的角度、状态和频率；正式跟随配置就绪后自动记录。无视频、设备标识或网络密码；退出应用后不保留记录。")
            }.listRowBackground(HeadLinkUI.group)
            Section {
                Button("生成脱敏诊断文件",systemImage:"doc.badge.plus") { model.exportDiagnostics() }
                if let url=model.exportURL { ShareLink("分享 JSON",item:url) }
                Button("清除记录",role:.destructive) {
                    model.diagnostics=[]
                    if let url=model.exportURL { try? FileManager.default.removeItem(at:url) }
                    model.exportURL=nil
                }
            }.listRowBackground(HeadLinkUI.group)
        }.headLinkList().navigationTitle("本地诊断").navigationBarTitleDisplayMode(.inline)
    }
}

private struct LiveDiagnosticsView:View {
    @Bindable var model:AppModel
    var body:some View {
        let _=model.controlRevision
        Form {
            Section { DisclosureGroup("跟随配置与说明") {
                Text(model.axes == .both ? "左右＋上下 1∶1" : model.axes == .yaw ? "仅左右 1∶1" : "仅上下 1∶1").font(.body.weight(.medium))
                Text(model.mountMode == .fixed ? "机身竖直固定 · 重力水平参考 · 倍率1.00" : "移动机身 · 相对拨动 · 不锁定世界方向").font(.footnote).foregroundStyle(.secondary)
                if !model.profileReady { Text("等待匹配真实机型的正式协议配置").foregroundStyle(.orange) }
                if model.profileReady,let limits=model.controller.limits {
                    Text("正式方向跟随 · 协议可达范围").font(.footnote)
                    Text(String(format:"机身坐标 yaw %.1f…%.1f° / pitch %.1f…%.1f°",limits.yawMin,limits.yawMax,limits.pitchMin,limits.pitchMax)).font(.footnote).monospacedDigit()
                }
                if model.profileReady && !model.controller.hasCalibration {
                    Text("看向正前方，让镜头对准对应方向，点击校准后开始。").font(.footnote)
                }
                Text(model.isFollowing ? "目标随头部更新，保持姿势即保持目标" : "校准成功后请明确点击开始跟随").font(.footnote)
            }
            }.listRowBackground(HeadLinkUI.group)
            Section("精度与诊断") { DiagnosticsPanel(model:model) }.listRowBackground(HeadLinkUI.group)
        }.headLinkList().navigationTitle("实时数值与图传").navigationBarTitleDisplayMode(.inline)
    }
}

private struct AboutHeadLinkView:View {
    var body:some View {
        Form {
            Section {
                LabeledContent("版本",value:(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "开发构建"))
                LabeledContent("构建号",value:Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "不可用")
                if let provenance=BuildProvenance.current {
                    LabeledContent("源码分支",value:provenance.branch)
                    Text("源码提交：\(provenance.commit)").font(.footnote.monospaced()).textSelection(.enabled)
                } else { Text("源码提交未嵌入此测试构建").font(.footnote).foregroundStyle(.secondary) }
                Text("原生 iPhone 工具，数据在本地处理。无需账号，无广告，不上传运动数据或相机画面。")
                Text("固定方向跟随与移动相对控制分别运行。移动相对控制不包含世界坐标补偿，受控输入测试不代表真机通过。").font(.footnote).foregroundStyle(.secondary)
            }.listRowBackground(HeadLinkUI.group)
            Section {
                NavigationLink("开源许可与署名") {
                    ScrollView { Text(licenseText).font(.footnote).textSelection(.enabled).padding() }.navigationTitle("开源许可")
                }
            } footer: { Text("使用 OpenCine / OpenPocketCine 的 Apache-2.0 开源实现。与 Apple、DJI 无官方关联。") }.listRowBackground(HeadLinkUI.group)
        }.headLinkList().navigationTitle("关于 HeadLink").navigationBarTitleDisplayMode(.inline)
    }
    private var licenseText:String {
        ["NOTICE","LICENSE"].compactMap { name in
            Bundle.main.url(forResource:name,withExtension:"txt").flatMap{try? String(contentsOf:$0,encoding:.utf8)}
        }.joined(separator:"\n\n")
    }
}
