# 移动机身补偿：真实数据核实与当前阻塞

2026-10-17。用户已确认1.2.0（8）固定机身1∶1正常。已保存远端标签`baseline-fixed-1.2.0-build-8`→`3e48086e9a07bad6d0a5fedbaca248eb6cb7bf91`及本地`work/baseline/moving-before-fixed-1.2.0.zip`。App、既有Sources/Tests与保存时逐字比较未变；固定版55项回归通过，Vendor236文件哈希未变。

**当前没有完成移动控制绑定，没有发布移动版IPA，也没有把未接通的模式按钮当作功能交付。** 固定版仍是可用版本。阻塞是数据与物理定义，不是用更多欧拉角运算就能补齐的输入。

## 数据证据分层

| 量 | 当前获得方式 | 可用定义 | 未核实项 |
| --- | --- | --- | --- |
| AirPods姿态 | `App/HeadphoneMotion.swift:25`，CMDeviceMotion.quaternion/gravity/timestamp | 耳机轴沿用已实测固定映射；本机保存sensorTime及回调收到时刻，重力用于水平参考 | CMHeadphoneMotionManager没有选择真北参考的接口，也没有供App读取的参考epoch；不能承诺无漂移/任何系统重定向都可检测 |
| 当前相机角度 | `App/PocketCamera.swift:164`，50字节0x04/0x05 | @4 yaw，-@20显示pitch，@0 native pitch，0.1°；固定机身运动已由用户验证 | 不能把这些数自动视为倾斜握持时完整且独立的三轴关节旋转 |
| 镜头姿态四元数 | 固定Vendor已有`OpenCineDJI/WorldLevel+DJI.swift:8` | @24/28/32/36 float32顺序x/w/y/z；上游作为world→camera，camera x前、y上、右手系，世界重力-y；归一化检查 | 上游拟合重力倾角，航向free且未使用；不同握持/滚转符号尚未完整资格确认。本App以前未接收/导出该量，用户旧JSON无此字段 |
| 机身姿态 | 当前无独立已核实来源 | 不可用 | 不可把镜头四元数重命名成机身四元数；不能把分离iPhone替代机身 |
| 完整R_BL云台旋转 | 需要物理关节定义或独立测量 | 不可用 | joint roll、pitch参考、旋转顺序及其时间关系不足；未知i16字段不猜作IMU |
| 原生命令 | `Commands.swift:549`，0x04/0x14 mode05 | yaw/nativePitch i16LE 0.1°、roll ignored、100ms；固定机身链路实测 | 倾斜握持下命令pitch与镜头世界倾角/机械关节角的关系未被固定机身验收证明 |
| 相机时间 | `App/PocketCamera.swift:174`在Main回调赋receivedAt | App收到回报的uptime，不是相机传感器时刻 | 目前无已核实的测量时钟、传输延迟上界或与AirPods的时钟映射；同包字段仍需核实采样关系 |

先前“50字节已知字段只有关节/原生反馈”的描述不完整，本次已更正：其中确实还有镜头重力姿态四元数。**任意航向初始偏置可以在校准时对齐，本身不使补偿不可能**；需要核实的是持续变化的相对航向、是否重置及机身/关节变换，不能把“heading free”误解释为所有yaw都不可测。

本机SDK头文件确认耳机API无显式reference frame选项；`TrackingController.swift:75`处理sensorTime倒退、采样间隔与参考跳变，`HeadphoneMotion.swift`以generation丢弃旧回调。已有保护不等于能检测任意缓慢参考修正。Apple定义：[CMHeadphoneMotionManager](https://developer.apple.com/documentation/coremotion/cmheadphonemotionmanager)、[CMAttitudeReferenceFrame](https://developer.apple.com/documentation/coremotion/cmattitudereferenceframe)。

## 正确推导与可观测性

统一采用列向量及右手旋转，R_AB把B坐标转换到A，组合从右向左。W为空间参考，B为机身，L为镜头，H为头部参考：

- 已对齐的头部方向产生空间目标`d_W_target`；保留校准得到的常量关系，移动机身不改变它。目标姿态从该射线和世界重力建立，侧歪头不增加目标roll。
- 机身目标射线：`d_B_target = R_WB(t)^T · d_W_target`。
- 完整目标旋转：`R_BL_target = R_WB(t)^T · R_WL_target`。
- 只有存在**完整、独立且时间对齐**的实测`R_WL`及`R_BL`时，才可反推`R_WB = R_WL · R_BL^T`。
- 然后还须通过已经核实的机械旋转顺序/原生指令参考系，把`R_BL_target`转换成实际控制目标。不能把这一步省成云台yaw与头部yaw相减。

可观测性反例：机身A不滚转、关节不滚转；机身B沿光轴滚转40°、云台关节反向滚转40°。两者镜头世界姿态相同，pan均为0、世界倾角相同，但机身旋转不同。若没有独立的完整关节滚转/倾角，已核实字段不能区分它们。这只证明**当前已核实的测量集合不足**，不是证明50字节包的所有未知字段永远不含需要的信息。

仅抄完整镜头四元数也不能解决：它包含机身运动和云台运动，必须以真实完整关节旋转分离，或提供独立机身传感器。平移不出现在以上方向方程中，不能积分加速度后拿位移当旋转补偿。

## 已完成的独立代码与测试

在隔离研究包`research/moving-body-prototype`准备旋转组合、完整测量反推机身、四元数SLERP及同一测量时刻对齐、参考ID/时钟变化拒绝、陈旧数据拒绝和理想双轴限位恢复。**它没有被App导入，也不能发送角度命令；理想双轴投影不是已经核实的Pocket三维机械模型。**

15项数学测试通过：头不动机身转、头身同转不重复、固定身原1∶1、同时不同轴/速、平移不改方向，以及复合旋转、roll水平、±180°连续、50/100Hz对齐、过期/不同时钟/只有收包时间时拒绝、真实参考变化、限位恢复与不可观测反例。固定版55项单独通过。不能合称“移动功能已通过70项”或硬件成功。

## 只询问实际安装，继续补证而不重复安装

已集中询问：Pocket手持/胸前肩带/其他，以及iPhone能否与Pocket刚性同支架转动。尚未收到答复。

- 若手机分离：不能使用其IMU测机身；优先核实包内能否形成完整关节测量与可靠镜头参考。若没有，需独立刚性机身传感器或厂家可核实姿态接口，不能软件凭空恢复。
- 若可刚性同支架：可评估iPhone Core Motion作为机身输入；仍要建立实际安装外参、独立参考之间的校准、时间对应及原生角度的倾斜模型。不能只勾选“已固定”就把手机姿态当机身。
- 厂家Direction Lock可保持方向，但单独切模式不能实现全部头部目标映射、机械可达性与复合角补偿，不作为本任务的替代成品。

为避免安装调查版，已准备`scripts/motion_capture`（另有本地独立目录HeadLink-motion-capture）。通过已有Mac `rvictl`/`tcpdump`，在现有App暂停跟随时，70秒只提取有效50字节姿态包，不发相机指令、不保存视频/网络地址/设备UDID。12项解析器测试通过；当前没有USB iPhone连接，**实际RVI链路未运行**。收包时间与阶段提示标签均不冒充传感器时间/物理角度真值。现有旧诊断JSON没有原始四元数，不能靠再次导出同种旧字段或反复校准解除此阻塞。

得到安装信息与必要测量后，再决定实际数据适配和控制绑定，完成回归、云端设备编译后只交付接通的移动IPA。本轮没有修改App或发布只有按钮的半成品。

## 主要来源

固定本地源码：`Vendor/OpenCine/Sources/OpenCineDJI/WorldLevel+DJI.swift`、`OpenCineMotion/WorldLevel.swift`、`OpenCineDJI/GimbalReach.swift`、`Commands.swift`、`DumlFrame.swift`、`DumlTransport.swift`；固定revision acc38b57d43d4308c79ad5ce951bcb6f44d14d68。

上游开发者记录：[云台坐标与尚未验证项](https://raw.githubusercontent.com/erik-sutton95/OpenPocketCine/main/docs/gimbal-controls.md)、[协议目录](https://opencapture.org/openpocketcine/docs/protocol/commands/)。未把上游物理数据当成本人设备验证，也未用其他DJI产品的DUML字段定义代替Pocket4证据。
