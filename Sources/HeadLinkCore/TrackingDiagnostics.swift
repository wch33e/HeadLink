import Foundation

public enum CalibrationInvalidationReason:String,Codable,Sendable {
    case explicitReset, connectionChanged, motionUnavailable, invalidQuaternion, sensorTimeReset
    case sampleGap, referenceJump, vertical, calibrationRequested, calibrationStale
    case inputStale, configurationUnavailable, schedulerGap, configurationChanged, modeChanged, sceneBackground, sceneInactive, experimentStarted, experimentAccepted, calibrationTimeout, userCleared
    public var message:String {
        switch self {
        case .connectionChanged:return "相机控制会话发生变化"
        case .motionUnavailable:return "耳机运动服务中断"
        case .invalidQuaternion:return "耳机姿态数值无效"
        case .sensorTimeReset:return "耳机传感器时间戳重置或倒退"
        case .sampleGap:return "控制器收到的耳机样本间隔超过200ms（源回调与消费延迟见诊断）"
        case .referenceJump:return "耳机姿态参考突变"
        case .vertical:return "头部方向接近竖直，解算不可用"
        case .calibrationRequested:return "用户明确开始新的校准"
        case .calibrationStale:return "校准期间输入数据过期"
        case .inputStale:return "运行时耳机或镜头数据过期"
        case .configurationUnavailable:return "机型协议角度配置不可用"
        case .schedulerGap:return "控制循环间隔超过200ms"
        case .configurationChanged:return "型号、固件或现场确认条件发生变化"
        case .modeChanged:return "相机报告云台模式不兼容"
        case .sceneBackground:return "应用进入后台"
        case .sceneInactive:return "校准期间应用失去活动状态"
        case .experimentStarted:return "用户开始单轴运动实验"
        case .experimentAccepted:return "用户启用新的实验角度配置"
        case .calibrationTimeout:return "稳定校准在12秒内未完成"
        case .userCleared:return "用户取消或清除校准"
        case .explicitReset:return "明确重置控制参考"
        }
    }
}
public struct CalibrationInvalidation:Codable,Sendable {
    public let sequence:UInt64
    public let calibrationID:UInt64
    public let reason:CalibrationInvalidationReason
    public let at:Double
    public let stateBefore:TrackingState
    public let headReceivedAt:Double?
    public let cameraReceivedAt:Double?
    public let cameraAngles:Angles?
    public let nativePitch:Double?
    public let limits:VerifiedLimits?
}
public enum TrackingStartRejection:String,Codable,Sendable {
    case disconnected, uncalibrated, limitsUnavailable, motionMissing, motionStale, motionFuture
    case cameraMissing, cameraStale, cameraFuture, outsideLimits
    public var message:String {
        switch self {
        case .disconnected:return "控制器未绑定已连接会话"
        case .uncalibrated:return "尚未校准头部与镜头方向"
        case .limitsUnavailable:return "未匹配有效的机型协议范围"
        case .motionMissing:return "控制器未收到耳机姿态"
        case .motionStale:return "耳机姿态超过200ms"
        case .motionFuture:return "耳机样本时间晚于本次控制时钟"
        case .cameraMissing:return "控制器未收到镜头姿态"
        case .cameraStale:return "镜头姿态超过300ms"
        case .cameraFuture:return "镜头样本时间晚于本次控制时钟"
        case .outsideLimits:return "当前镜头角度超出协议可达范围"
        }
    }
    var error:TrackingError {
        switch self {
        case .disconnected,.uncalibrated:return .uncalibrated
        case .limitsUnavailable:return .unavailable
        default:return .stale
        }
    }
}
