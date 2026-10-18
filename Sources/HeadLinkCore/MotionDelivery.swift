import Foundation

public struct MotionDeliveryDiagnostic:Codable,Sendable {
    public var callbacks=0
    public var errors=0
    public var lastCallbackAt:Double?
    public var lastErrorAt:Double?
    public var lastRecoveryAt:Double?
    public var lastCallbackGap:Double?
    public var maximumCallbackGap=0.0
    public var lastSensorTime:Double?
    public var sensorTimeNonIncreasingCount=0
    public init() {}
}

/// One newest real callback, not a FIFO. The owner supplies synchronization.
/// A recovered callback clears the CURRENT error; error history stays in diagnostics.
public struct MotionDelivery:Sendable {
    public private(set) var sample:MotionSample?
    public private(set) var failed=false
    public private(set) var diagnostic=MotionDeliveryDiagnostic()
    private var callbackTimes:[Double]=[]
    public init() {}
    public mutating func accept(_ next:MotionSample?,at time:Double) {
        diagnostic.callbacks += 1
        if let previous=diagnostic.lastCallbackAt {
            diagnostic.lastCallbackGap=time-previous
            diagnostic.maximumCallbackGap=max(diagnostic.maximumCallbackGap,time-previous)
        }
        diagnostic.lastCallbackAt=time
        guard let next else {
            failed=true; sample=nil; diagnostic.errors += 1; diagnostic.lastErrorAt=time
            return
        }
        if failed { diagnostic.lastRecoveryAt=time }
        failed=false
        if let previous=diagnostic.lastSensorTime,next.sensorTime <= previous { diagnostic.sensorTimeNonIncreasingCount += 1 }
        diagnostic.lastSensorTime=next.sensorTime
        sample=next
        callbackTimes.append(time); callbackTimes.removeAll { time-$0 > 2 }
    }
    public func reading(at time:Double) -> MotionReading {
        let span=(callbackTimes.last ?? 0)-(callbackTimes.first ?? 0)
        let fresh=sample.map{time >= $0.receivedAt && time-$0.receivedAt < 0.2} ?? false
        return .init(sample:sample,callbackHz:fresh && span > 0 ? Double(callbackTimes.count-1)/span : 0,failed:failed)
    }
}
