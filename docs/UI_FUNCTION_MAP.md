# 原生UI改版：冻结清单与入口对应

基线：已验证固定机身1.2.0（8），`3e48086e9a07bad6d0a5fedbaca248eb6cb7bf91`，标签`baseline-fixed-1.2.0-build-8`。独立UI源码目录HeadLink-UI；原HeadLink目录及移动稳定性分支保留。本次用户已明确先做纯UI，解除文档中“挂脖已完成”的启动前提，不把移动补偿加入本次范围。

## 功能与入口（改动前建立）

| 原入口/内容 | 条件及原动作 | 改版位置 |
| --- | --- | --- |
| 初次说明、知道了 | onboarded=false；只写onboarded=true | 设备页顶部紧凑说明，保留按钮 |
| 设备、进入拍摄 | shooting=false/true；仅导航及原常亮规则 | 顶部相机/耳机状态进入设备页，返回监看；视频容器留在根视图 |
| 耳机状态、观察yaw/pitch、实际回调频率 | MotionLabel、probe.look、headAge≤0.2；1位小数°/Hz，原telemetryRevision | 设备页耳机区；真实数值页保留全部原指标 |
| 检查运动数据 | retryMotion()，连接页原无禁用条件 | 设备页耳机区 |
| 打开应用设置 | authorization==denied；UIApplication.open原URL | 设备页权限说明下 |
| 搜索相机 | camera.scan()，原无额外条件 | 设备页相机区 |
| 搜索结果 | camera.sightings；controller.connecting(); camera.connect(sighting) | 同页原生列表行 |
| 当前型号、固件、连接阶段、配对帮助 | 真实selected/model、firmware、message，不猜状态 | 设备页相机区，完整保留 |
| 手动Wi-Fi说明、SSID、显示/隐藏密码、复制密码、选中复制 | wifiRequest存在；reveal/copy为局部UI状态；仅明确复制写本机剪贴板，空密码禁用，密码变化复位两UI标志 | 设备页Wi-Fi区，规则原样保留 |
| 已加入Wi-Fi，验证连接 | camera.confirmWiFi() | 同区，保持原手动步骤 |
| 断开 | wifiRequest=nil时可见；camera.disconnect()，原无新增确认/禁用 | 设备页连接操作；关闭页面不调用它 |
| 跟随状态 | 原TrackingState→stateLabel，原文本映射不改 | 监看顶部与详情，不自判状态 |
| 校准 | !canCalibrate禁用；pause(); showingCalibration=true | 底部悬浮栏左/右（沿用左手布局） |
| 开始校准、校准中、取消 | 原canCalibrate；calibrate()；取消clearCalibration()+关闭；关闭时原calibrating检查 | 原生校准面板，保留所有动作及条件 |
| 开始/暂停/恢复跟随 | following时pause()；userPaused时原恢复确认；其余start()；!following&&!canStart禁用 | 底部主按钮；原alwaysPause入口仍直接可用 |
| 恢复确认 | 继续start()；重新对齐pause()+showingCalibration=true；取消无动作 | 原确认菜单，文字与动作保留 |
| 录像/停止、请求中、录像错误 | actualRecording真实值；toggleRecording()；nil或recordPending非nil禁用；真实recordElapsedSec秒 | 底部独立录制按钮、画面REC标签及等待状态 |
| 所有开始阻塞项、协议范围、校准说明、反馈误差说明 | blockers、formal/profileReady、limits、feedbackSummary；原单位与格式不变 | 阻止原因贴近主按钮；完整范围/说明在更多及详情 |
| 跟随状态与诊断 | **原入口明确先pause()**，再呈现CommissioningView | 更多中的同名按钮、设备页旧入口；保留暂停，返回不自动恢复 |
| 精度与诊断全部指标 | 原10Hz telemetryRevision，格式、数据源、可用性不变 | 更多→实时数值与图传；使用同一DiagnosticsPanel |
| 重试图传恢复 | retryVideoRecovery()；!connected禁用 | 更多→实时数值与图传 |
| 重新检查耳机运动服务 | retryMotion()；following禁用（与连接页不同，保持差异） | 跟随状态与诊断→耳机真实输入 |
| 读取模式参数 | refreshControlInfo()，原无额外禁用 | 跟随状态与诊断→相机真实回报 |
| 清除校准 | clearCalibration()，原无新增确认/禁用 | 更多→跟随区 |
| 诊断生成、分享、清理 | exportDiagnostics()；仅exportURL非nil显示ShareLink；清理原数组/临时文件/URL | 更多→本地诊断；跟随状态与诊断保留导出/分享 |
| 版本、隐私/限制说明、开源许可 | Bundle版本、原NOTICE/LICENSE资源与全部必要说明 | 更多→关于HeadLink→开源许可 |

无已有机械回中、自动连/自动跟随、缩放手势、主题选择或额外模式，因此不添加。已有移动枚举仍标未验证且由原业务层阻止运动，不能在UI重新命名为已支持挂脖。

## 全部用户配置

当前手机保存值不可从开发环境读取。原键、读取及写入原样保留，不清空、不迁移，默认值仅指首次安装；本次不写新的推荐值。

| 键/类型 | 首次默认与范围/单位 | 生效/保存 | 新入口 |
| --- | --- | --- | --- |
| axes / String | both；both/yaw/pitch，双轴/仅左右/仅上下；倍率显示1.00不可调 | AppModel原didSet先pause，再设置controller.axes，UserDefaults写rawValue | 更多→控制轴 |
| response / String | immediate；immediate/smooth | 原didSet先pause再改controller与保存；不改40ms等业务常量 | 更多→响应 |
| mountMode / String | fixed；fixed/movingUnverified，名称沿用MountMode.title | 只在枚举变化时原revokeExperiment清校准及保存 | 更多→安装方式；跟随详情保留第二入口 |
| crosshair / Bool | true | 原AppStorage立即保存；只控制原十字线 | 更多→画面与反馈 |
| leftHanded / Bool | false | 原AppStorage立即保存；只改变操作区的左右视觉排列 | 同上 |
| keepAwake / Bool | false | 原AppStorage；原shooting/keepAwake onChange设置idleTimer；后台规则不改 | 同上 |
| haptics / Bool | false | 原AppStorage立即保存；由原AppModel.haptic读取，不加新震动 | 同上 |
| recordDiagnostics / Bool | false | 原AppStorage立即保存；原10Hz/6000条记录及profileReady自动记录逻辑不改 | 更多→本地诊断 |
| onboarded / Bool | false | 原AppStorage，只由知道了设true | 设备页初次说明 |

无用户可调数值滑块、输入框、步长或连续参数范围。协议限位、采样/命令节拍、阈值、速度、平滑、校准稳定性等均是冻结业务代码，不能当成设计参数改动。密码显示/复制、面板展开和导航状态仅为原有/新增纯展示状态，不作为业务条件。

## 状态与生命周期冻结

全部TrackingState保留：disconnected/connecting/waitingMotion/ready/calibrating/calibrated/following/userPaused/stalePaused/deviceDisconnected/fault。连接message、模式/固件未知、权限拒绝、耳机过期、真实录制/待确认/错误、previewLive与videoMessage、超限提示和全部blockers均来自原数据源。

HeadLinkApp、AppModel、PocketCamera、PocketCamera+Video、HeadphoneMotion、Sources、Tests、Vendor、Info.plist原样逐字核验；新UI不创建控制器/相机/解码器，不添加task、onAppear启停、轮询或计时器。PreviewSurface/VideoContainer的绑定、resizeAspect和layout实现保持逐字相同；根视图保持同一视频位置，不因设备页/设置面板变化替换它。校准与恢复原确认保留，普通面板不添加业务动作。

## 材质依据

SDK仍为Xcode26.1.1，部署目标iOS17。iOS26分支使用Apple原生[glassEffect](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:))，旧系统regularMaterial；减少透明度用实体系统背景，减少动态效果用稳定系统材质。无自定义shader、逐帧采样或第三方UI库。监看保留深色机制，未新增主题。
