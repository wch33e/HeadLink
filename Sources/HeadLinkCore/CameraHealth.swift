import Foundation

/// Received telemetry proves an inbound control path, not command acknowledgement or Wi-Fi SSID.
public struct CameraHealthEvidence:Codable,Sendable {
    public let now:Double
    public let connected:Bool
    public let endpointPresent:Bool
    public let endpointClosed:Bool
    public let flowHealthy:Bool
    public let rebuilding:Bool
    public let cameraSubnetPresent:Bool
    public let controlAt:Double?
    public let videoAt:Double?
    public init(now:Double,connected:Bool,endpointPresent:Bool,endpointClosed:Bool,flowHealthy:Bool,
                rebuilding:Bool,cameraSubnetPresent:Bool,controlAt:Double?,videoAt:Double?) {
        self.now=now; self.connected=connected; self.endpointPresent=endpointPresent; self.endpointClosed=endpointClosed
        self.flowHealthy=flowHealthy; self.rebuilding=rebuilding; self.cameraSubnetPresent=cameraSubnetPresent
        self.controlAt=controlAt; self.videoAt=videoAt
    }
    public func fresh(_ t:Double?,within age:Double) -> Bool { t.map{$0 <= now && now-$0 < age} ?? false }
    public var controlFresh:Bool { fresh(controlAt,within:1) }
    public var videoFresh:Bool { fresh(videoAt,within:1) }
    public var classification:String {
        if !connected { return "session_closed" }
        if rebuilding { return "shared_transport_rebuilding" }
        if !endpointPresent || endpointClosed { return "local_endpoint_closed" }
        if controlFresh {
            if !flowHealthy { return "inbound_control_alive_outbound_unavailable" }
            return fresh(videoAt,within:2) ? "control_and_video_ingress_alive" : "control_alive_video_ingress_stale"
        }
        if videoFresh { return "video_ingress_alive_control_stale" }
        if !cameraSubnetPresent { return "camera_subnet_absent_control_stale" }
        if !flowHealthy { return "local_transport_unavailable_control_stale" }
        return "transport_ready_control_stale"
    }
}

/// Preserve the existing 1 s local-flow failure threshold, but require independent lack of inbound
/// control evidence. Motion, angle limits, video loss and calibration are deliberately not inputs.
public struct CameraSessionHealthPolicy:Sendable {
    public private(set) var unhealthySince:Double?
    public init() {}
    public mutating func disconnectReason(_ e:CameraHealthEvidence) -> String? {
        guard e.connected,!e.rebuilding else { unhealthySince=nil; return nil }
        if !e.endpointPresent || e.endpointClosed { return "local_endpoint_closed" }
        guard !e.flowHealthy,!e.controlFresh,!e.videoFresh else { unhealthySince=nil; return nil }
        if unhealthySince == nil { unhealthySince=e.now }
        guard e.now-(unhealthySince ?? e.now) >= 1 else { return nil }
        return e.cameraSubnetPresent ? "local_transport_unavailable_without_control_1s" : "camera_subnet_absent_transport_unavailable_1s"
    }
}
