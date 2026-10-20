import Foundation

public struct MotionReading:Sendable {
    public let sample:MotionSample?
    public let callbackHz:Double
    public let failed:Bool
    public let sourceErrorCount:Int?
    public let sourceGeneration:UInt64?
    public init(sample:MotionSample?,callbackHz:Double,failed:Bool,sourceErrorCount:Int? = nil,sourceGeneration:UInt64? = nil) {
        self.sample=sample; self.callbackHz=callbackHz; self.failed=failed; self.sourceErrorCount=sourceErrorCount; self.sourceGeneration=sourceGeneration
    }
}

/// Evaluate freshness against a clock read AFTER both input snapshots.
/// Reading the clock first can misclassify a concurrently arriving sensor sample as future data.
public struct ControlInputFrame:Sendable {
    public let motion:MotionReading
    public let camera:CameraPose?
    public let evaluatedAt:Double
    public static func capture(readMotion:()->MotionReading,readCamera:()->CameraPose?,clock:()->Double) -> Self {
        let motion=readMotion()
        let camera=readCamera()
        return .init(motion:motion,camera:camera,evaluatedAt:clock())
    }
}

/// Discrete controls publish only on a change; telemetry has its own bounded cadence.
/// Neither policy gates or slows the motor loop or sensor callbacks.
public struct PresentationGate<Control:Equatable> {
    private var lastControl:Control?
    private var lastTelemetryAt:Double?
    public init() {}
    public mutating func updates(control:Control,at now:Double) -> (controls:Bool,telemetry:Bool) {
        let changed=lastControl != control
        if changed { lastControl=control }
        let telemetry=now.isFinite && (lastTelemetryAt.map { now < $0 || now-$0 >= 0.1 } ?? true)
        if telemetry { lastTelemetryAt=now }
        return (changed,telemetry)
    }
}
