import Foundation

public enum MountMode:String,CaseIterable,Sendable {
    case fixed
    case movingRelative = "movingUnverified"
    public var title:String { self == .fixed ? "机身竖直固定" : "移动机身（相对）" }
}

/// Pinned native protocol reach, NOT the personal 5-degree test envelope and NOT
/// DJI's differently-signed specification table. Hardware may impose stricter limits.
public enum FormalFollowProfile {
    public static let model="Osmo Pocket 4"
    public static let source="opencine-acc38b57-handle-reach; full-device-range-not-personally-measured"
    public static func limits(model:String?,reportedFirmware:String?) -> VerifiedLimits? {
        guard model == Self.model else { return nil }
        return .init(model:Self.model,firmware:reportedFirmware ?? "not-reported",
            evidence:source,yawMin:-48,yawMax:225,pitchMin:-44,pitchMax:70)
    }
}
