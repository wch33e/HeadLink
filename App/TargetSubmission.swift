import HeadLinkCore

enum CameraTargetRejection:String,Codable {
    case transportUnavailable,poseUnavailable,pathUnreachable,streamInactive,encodingRejected,mailboxRejected
}
enum TargetSubmission {
    /// Values actually encoded at 0.1 degrees, after legal limits and the existing transition.
    case accepted(Angles,nativePitch:Double)
    case rejected(CameraTargetRejection)
    var accepted:Bool { if case .accepted = self { return true }; return false }
}

enum FollowPauseReason:String {
    case user,inactive,videoRecovery,mode,path,submission,feedback,start
    var summary:String {
        switch self {
        case .user:return "用户暂停"
        case .inactive:return "暂时失活，已暂停"
        case .videoRecovery:return "图传恢复，已暂停"
        case .mode:return "云台模式未就绪"
        case .path:return "路径受限，已暂停"
        case .submission:return "目标提交失败，已暂停"
        case .feedback:return "反馈偏差，已暂停"
        case .start:return "跟随未启动"
        }
    }
}
