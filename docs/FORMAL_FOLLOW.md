# 1.2.0 正式方向跟随：实现、依据与边界

2026-10-17。用户已确认1.1.2（7）允许的局部范围内头部联动通过；这是用户报告的硬件结果，不延伸为本版大角度、精度、延迟或移动补偿认证。基线标签baseline-1.1.2-build-7指向5f1654a03d611042cf591952637767c8f4c31c4f，原IPA及本地work/baseline/formal-follow-before.zip保留。

## 正常入口

真实连接识别Osmo Pocket 4后自动加载正式协议配置，自动查询云台模式；不再核对三项实验开关、不要求每次左右/上下观察3°、不要求四向5°实验及返回确认，也不要求人工重复填写无法读取的固件。自动加载配置不运动，完成校准也不运动，仍由用户点击开始。固件只记录真实回报；缺失写not-reported，历史人工01.03.14.04不是本次读取，也不作为型号猜测。

用户层面流程：连接 → 校准 → 开始。原实验UI与启用动作已退出App正常路径；历史JSON配置、证据、核心测试仍保留，不再限定正式控制。

## 方向、单位与复合姿态

- 耳机沿用已经接通的Core Motion四元数，+X向右、+Y鼻尖、+Z头顶。增加读取同一样本的gravity，使用其在设备坐标的方向建立参考空间的重力竖直。Apple说明：[gravity](https://developer.apple.com/documentation/coremotion/cmdevicemotion/gravity)、[CMAttitude](https://developer.apple.com/documentation/coremotion/cmattitude)。
- 校准平均稳定头部四元数，保存重力水平面内的正前方向和初始仰角，并保存当时相机真实yaw、显示pitch、native pitch。重力先用对应样本的四元数转到公共参考空间，再与平均朝向组合，避免混用两个时刻的坐标。
- 每次把当前鼻尖方向投影到同一个水平参考系：yaw取方位角差（连续展开），pitch取仰角差。roll只改变鼻尖周围姿态，不改变该方向。原inverse(q0)*q在校准时头部俯仰/侧歪后会倾斜yaw平面，正式路径改用此重力水平参考。
- cameraYawTarget = calibrationCameraYaw + headYawDelta；cameraDisplayPitchTarget = calibrationCameraDisplayPitch + headElevationDelta。两个系数固定1.00。不是把复合姿态的Euler角直接相减；测试覆盖校准头部yaw65°/pitch20°/roll35°后分别增加30°/30°，以及任意运动参考系、过±180°、侧歪不串轴和回到基准。
- 已跑通的0x04/0x14绝对目标模式0x05不变；i16LE、0.1°单位、roll ignored、100ms固件运动窗口。nativePitchTarget = wrap(calibrationNativePitch - (displayPitchTarget-calibrationDisplayPitch))，不是把显示pitch直接编码成原生pitch。50字节0x04/0x05反馈：yaw@4、native pitch@0、显示pitch=-@20。
- 保持头部姿势，绝对目标不再增加；回到基准，目标返回保存基准。无速度摇杆、无倍率压缩、无限位后重新定零。

## 范围与相机模式

正式范围采用固定OpenCine acc38b57的GimbalReach声明：**机身反馈坐标yaw -48…225°，display pitch -44…70°**。个人±5°软件窗口不再使用。该范围由上游操作者确认并被现有原生目标路径检查实际采用；**这台个人设备的大角度端点尚未逐一实测**，不把它宣传为厂家机械极限或本机全行程认证。

[DJI Pocket 4产品支持规格](https://www.dji.com/au/support/product/osmo-pocket-4)列出的操控与机械范围使用厂商规格坐标；检索可见其操控pan -235…58°、tilt -120…70°，机械pan -240…63°、tilt -180…98°。这些不是当前反馈同号同原点的数值，**没有据此扩大协议坐标**。本版开放已实现的协议可达范围，不尝试推到机械止挡。

目标超限保留raw角度并夹到可达边界，屏幕明确提示“不可达：已限位，未缩放倍率”；不会偷偷改基准。校准原点不一定在正中央，因此相对可转角度取决于校准时镜头位置。底层真实限位继续由相机执行；协议边界、反馈300ms新鲜度与不可达yaw扇区检查保留。当前回报与新绝对目标差≥180°时拒绝短弧跳转，显示具体原因，不把它解释成断连。

[DJI手册4.2节](https://dl.djicdn.com/downloads/DJI_Osmo_Pocket_4/UM/v1.0/Osmo_Pocket_4_User_Manual_en.pdf)说明Follow保持roll水平，FPV跟随手柄全部方向。本版只接受真实Follow和新鲜的俯仰未锁定参数，不擅自切换相机模式。模式参数每2秒查询，3秒后过期即暂停，恢复后需明确继续。ActiveTrack/智能云台可能竞争运动，需在机身关闭；当前没有可靠独立状态字段证明其关闭，不伪造该状态。

## 反馈与低延迟

优先复用目标邮箱和25Hz原生发送上限，容量一、旧token围栏、200ms命令过期不变。低延迟稳定跟随直接提交最新方向，不再逐帧叠加30°/s客户端追赶。只有开始/恢复保留120°/s、720°/s²的有限过渡保护；这些是保护参数，不是已测的物理速度。轻度平滑时间常数40ms，终值不改。100ms是协议运动窗口，不是测量出的端到端延迟。

新增FollowFeedbackMonitor只对目标停稳后的**真实相机回报**核对yaw、显示pitch和原生pitch。目标在0.5°内保持350ms后观察，任一残差持续超过2.5°达1秒则暂停，保留有效头部校准，不调倍率或基准。移动/过期回报不能标记为到位。2.5°为异常阈值，绝非宣称精度；到达该阈值内也不是独立光学测量。诊断同时导出原始目标、限位目标、命令、真实回报、校准原点、重力水平基向量和反馈差值，便于核对符号、单位和原生pitch参考。

## 机身移动与安装约束

当前交付明确为**Pocket机身竖直固定**。倾斜固定安装的三维外参和移动基座均未验证。把身体转动简单加到头部增量上会重复转动；同理不能把云台关节反馈当作世界姿态后相减。真实补偿需要独立且同步的机身世界姿态与传感器安装外参，用世界目标变换到当前机身坐标；本次补充核实：50字节包还包含@24…@39的镜头姿态四元数，上游已用其做重力水平仪；它不是独立机身姿态。完整关节旋转、倾斜握持定义和动态时序仍待核实，详见MOVING_BODY_FEASIBILITY.md。未凭未知偏移解码IMU，也未把随手放置的iPhone当作机身传感器。

设置保留“移动机身（补偿未验证）”显式标签，该选项会停止运动/清除校准并阻止以固定映射启动，不会让身体转一次又由云台重复转一次。用户随后已明确Pocket挂脖、iPhone分离；安装条件已确定，移动模式仍缺已核实的完整机身/关节测量，不冒称已实现。故障分层优先修复见NECK_MOVEMENT_INVESTIGATION.md。

## 保留与验证

与保存基线比较，PocketCamera的配对/手动Wi-Fi、状态接收、目标所有权、录像、连接健康及整个PocketCamera+Video恢复文件逐字一致；只在角度提交处增加不可达扇区的明确拒绝，在模式查询旁增加正式启动条件。Vendor236文件哈希不变。暂停、重新对齐、数据过期/参考跳变、后台、断连、重连不自动跟随继续有效。

相关测试：FormalFollowTests覆盖自动机型配置/无实验校准、±30°和复合30°、保持/回基准、roll、非零校准、yaw连续、native pitch参考、低延迟及恢复保护、限位不改倍率、反馈符号/原生单位错误、移动/过期不误报到位和自然小幅保持抖动不掩盖无响应。相机反馈在自动测试中为合成数据，不属于硬件验收。完整编译及产物记录见PROGRESS.md和TEST_RESULTS.md。

## 关键代码位置（1.2.0）

- `Sources/HeadLinkCore/HeadDirectionReference.swift`：重力水平参考与复合朝向。
- `Sources/HeadLinkCore/FormalFollowProfile.swift`：正式机型、明确来源的协议范围与安装模式。
- `Sources/HeadLinkCore/TrackingController.swift:103`：稳定校准；`:160`：绝对目标与低延迟/起步过渡。
- `App/AppModel.swift:136`：自动匹配；`:286`/`:294`：校准及开始；`:206`：反馈核对；`:337`：schema4导出。
- `App/PocketCamera.swift:187`：真实编码/队列与不可达扇区拒绝；`:214`：真实模式条件。
- `Sources/HeadLinkCore/FollowFeedback.swift`、`Tests/HeadLinkCoreTests/FormalFollowTests.swift`：反馈状态与正式跟随回归。
