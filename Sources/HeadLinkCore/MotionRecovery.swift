import Foundation

/// Recovery scheduling is separate from the 200 ms safety freshness gate.
/// At most three actual starts per foreground epoch; unavailable hardware consumes no attempt.
public struct MotionRecoveryPolicy:Sendable {
    public enum Action:Sendable,Equatable { case start,restart }
    public private(set) var attempts=0
    public private(set) var lastAttemptAt:Double?
    public init() {}
    public mutating func beginForeground() { self = .init() }
    public mutating func action(at now:Double,available:Bool,authorized:Bool,active:Bool,sampleAt:Double?) -> Action? {
        guard available,authorized,attempts < 3 else { return nil }
        if let sampleAt,now >= sampleAt,now-sampleAt < 0.2 { return nil }
        let delay=attempts < 2 ? 1.0 : 3.0
        if let lastAttemptAt,now-lastAttemptAt < delay { return nil }
        // An already-active OS service gets one second to deliver after foregrounding.
        if active,lastAttemptAt == nil { lastAttemptAt=now; return nil }
        let result:Action=active ? .restart : .start
        attempts += 1; lastAttemptAt=now
        return result
    }
}
