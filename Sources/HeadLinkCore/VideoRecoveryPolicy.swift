import Foundation

public struct VideoPipelineSample:Codable,Sendable {
    public let now:Double
    public let startedAt:Double
    public let connected:Bool
    public let transportReady:Bool
    public let packetAt:Double?
    public let accessUnitAt:Double?
    public let decoderOutputAt:Double?
    public let presentedAt:Double?
    public let decoderFailed:Bool
    public let awaitingKeyframe:Bool
    public let cameraSetAt:Double?
    public let controlFrameAt:Double?
    public init(now:Double,startedAt:Double,connected:Bool,transportReady:Bool,packetAt:Double?,accessUnitAt:Double?,
                decoderOutputAt:Double? = nil,presentedAt:Double?,decoderFailed:Bool = false,awaitingKeyframe:Bool = false,cameraSetAt:Double? = nil,controlFrameAt:Double? = nil) {
        self.now=now; self.startedAt=startedAt; self.connected=connected; self.transportReady=transportReady
        self.packetAt=packetAt; self.accessUnitAt=accessUnitAt; self.decoderOutputAt=decoderOutputAt
        self.presentedAt=presentedAt; self.decoderFailed=decoderFailed; self.awaitingKeyframe=awaitingKeyframe; self.cameraSetAt=cameraSetAt
        self.controlFrameAt=controlFrameAt
    }
    public func fresh(_ stamp:Double?,within seconds:Double) -> Bool {
        stamp.map { $0 <= now && now-$0 < seconds } ?? false
    }
    /// A retained picture never refreshes these timestamps.
    public var live:Bool { connected && fresh(presentedAt,within:0.7) && fresh(accessUnitAt,within:1) && !decoderFailed && !awaitingKeyframe }
}
public enum VideoRepairAction:String,Codable,Sendable { case registerAndEnable, repairPresentation, repairDecoderAndEnable, rebuildSharedTransport }
public enum VideoRecoveryState:String,Codable,Sendable { case idle, healthy, stalled, recovering, failed }

/// One bounded repair cycle. Fresh AUs forbid a transport rebuild: repair only the decoder.
/// Stable fresh pictures re-arm the cycle; repeated short-lived recoveries retain their budget.
public struct VideoRecoveryPolicy:Sendable {
    public private(set) var state:VideoRecoveryState = .idle
    public private(set) var attempts=0
    public private(set) var lastActionAt:Double?
    public private(set) var reason=""
    private var healthySince:Double?
    public init() {}
    public mutating func tick(_ input:VideoPipelineSample,busy:Bool = false) -> VideoRepairAction? {
        guard input.connected else { state = .idle; return nil }
        if input.live {
            if healthySince == nil { healthySince=input.now }
            state = .healthy; reason="fresh_source_presentation"
            if input.now-(healthySince ?? input.now) >= 10 { attempts=0; lastActionAt=nil }
            return nil
        }
        healthySince=nil
        guard input.now-input.startedAt >= 4 else { return nil }
        if input.fresh(input.presentedAt,within:2), !input.decoderFailed,!input.awaitingKeyframe { return nil }
        if state == .failed { return nil }
        reason=input.fresh(input.accessUnitAt,within:2) ? "decode_or_present_stall" :
            (input.fresh(input.packetAt,within:2) ? "access_unit_assembly_stall" : "video_ingress_stall")
        if busy { state = .recovering; return nil }
        if let lastActionAt,input.now-lastActionAt < 4 { return nil }
        // A record/parameter change can pause the encoder briefly, but cannot hold repair forever.
        if input.fresh(input.cameraSetAt,within:4),input.fresh(input.packetAt,within:6) { return nil }
        guard attempts < 3 else { state = .failed; reason += ":retry_budget_exhausted"; return nil }
        let action:VideoRepairAction
        if input.fresh(input.accessUnitAt,within:2) {
            guard attempts < 2 else { state = .failed; reason="decoder_still_stalled_transport_kept"; return nil }
            action = input.fresh(input.decoderOutputAt,within:2) && attempts == 0 ? .repairPresentation : .repairDecoderAndEnable
        } else if attempts < 2 { action = .registerAndEnable }
        else {
            // A video-only failure must not destroy a working control session or calibration.
            // Leave the last repair slot unused; if control later actually goes stale the shared
            // repair is still available. Manual retry explicitly starts a new bounded cycle.
            guard !input.fresh(input.controlFrameAt,within:3) else {
                state = .stalled; reason += ":control_alive_shared_transport_kept"; return nil
            }
            action = .rebuildSharedTransport
        }
        attempts += 1; lastActionAt=input.now; state = .recovering
        return action
    }
    public mutating func fail(_ reason:String) { state = .failed; self.reason=reason }
}
