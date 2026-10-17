import Foundation
import HeadLinkCore

// Offline research only. No App imports this module and it cannot send camera commands.
// Every frame here is canonical +X right, +Y forward, +Z up. Real DJI optical-frame
// conversion, full joint kinematics and source clock bounds must be qualified before binding.
public enum PoseQuality:Sendable { case measuredOrientation, derivedFromCompleteMeasuredRotations, receiptTimeOnly }
public enum CompensationError:Error,Equatable { case unobservableBody, clockMismatch, stale, unbracketed, referenceChanged, invalidOrder, unreachable }
public struct TimedRotation:Sendable {
    public let rotation:Quaternion
    public let measuredAt:Double
    public let receivedAt:Double
    public let clockID:String
    public let referenceID:String
    public let quality:PoseQuality
    public init(_ rotation:Quaternion,at:Double,receivedAt:Double? = nil,clock:String="aligned-host-uptime",reference:String="fixture-world",quality:PoseQuality = .measuredOrientation) {
        self.rotation=rotation; measuredAt=at; self.receivedAt=receivedAt ?? at
        clockID=clock; referenceID=reference; self.quality=quality
    }
}
public struct RotationTimeline:Sendable {
    public private(set) var samples:[TimedRotation]=[]
    public init() {}
    public mutating func append(_ sample:TimedRotation) throws {
        guard sample.measuredAt.isFinite,sample.receivedAt.isFinite,sample.measuredAt <= sample.receivedAt,(try? sample.rotation.normalized()) != nil else { throw CompensationError.invalidOrder }
        if let last=samples.last {
            guard sample.clockID == last.clockID else { throw CompensationError.clockMismatch }
            guard sample.referenceID == last.referenceID else { throw CompensationError.referenceChanged }
            guard sample.measuredAt > last.measuredAt else { throw CompensationError.invalidOrder }
        }
        samples.append(sample); if samples.count > 64 { samples.removeFirst(samples.count-64) }
    }
    public func interpolate(at time:Double) throws -> TimedRotation {
        guard let first=samples.first,let last=samples.last,time >= first.measuredAt,time <= last.measuredAt else { throw CompensationError.unbracketed }
        if let exact=samples.first(where:{$0.measuredAt == time}) {
            guard exact.quality != .receiptTimeOnly else { throw CompensationError.unobservableBody }
            return exact
        }
        guard let upper=samples.firstIndex(where:{$0.measuredAt > time}),upper > 0 else { throw CompensationError.unbracketed }
        let a=samples[upper-1],b=samples[upper]
        guard a.quality != .receiptTimeOnly,b.quality != .receiptTimeOnly else { throw CompensationError.unobservableBody }
        guard b.measuredAt-a.measuredAt <= 0.1 else { throw CompensationError.unbracketed }
        let q=try slerp(a.rotation,b.rotation,(time-a.measuredAt)/(b.measuredAt-a.measuredAt))
        return .init(q,at:time,receivedAt:max(a.receivedAt,b.receivedAt),clock:a.clockID,reference:a.referenceID,quality:a.quality)
    }
}
public func slerp(_ start:Quaternion,_ end:Quaternion,_ t:Double) throws -> Quaternion {
    let a=try start.normalized(); var b=try end.normalized()
    var dot=a.w*b.w+a.x*b.x+a.y*b.y+a.z*b.z
    if dot < 0 { b = .init(w:-b.w,x:-b.x,y:-b.y,z:-b.z); dot = -dot }
    let u:Double,v:Double
    if dot > 0.9995 { u=1-t; v=t }
    else { let theta=acos(min(1,dot)); u=sin((1-t)*theta)/sin(theta); v=sin(t*theta)/sin(theta) }
    return try Quaternion(w:u*a.w+v*b.w,x:u*a.x+v*b.x,y:u*a.y+v*b.y,z:u*a.z+v*b.z).normalized()
}
public struct AlignedRotations:Sendable {
    public let head:TimedRotation
    public let body:TimedRotation
    public let time:Double
    public static func latest(head:RotationTimeline,body:RotationTimeline,now:Double) throws -> Self {
        guard let h=head.samples.last,let b=body.samples.last else { throw CompensationError.unbracketed }
        guard h.clockID == b.clockID else { throw CompensationError.clockMismatch }
        let time=min(h.measuredAt,b.measuredAt)
        guard now >= time,h.receivedAt <= now,b.receivedAt <= now,now-time <= 0.2,now-h.receivedAt <= 0.2,now-b.receivedAt <= 0.2 else { throw CompensationError.stale }
        return try .init(head:head.interpolate(at:time),body:body.interpolate(at:time),time:time)
    }
}
public struct WorldCompensation {
    // Right-to-left composition: q_AB maps frame B into A.
    // q_WL_target = q_WHeadReference * q_head * q_head0^-1 * q_HeadReference_W * q_WL0
    // q_BL_target = q_WB^-1 * q_WL_target
    public let headReferenceToWorld:Quaternion
    public let head0:Quaternion
    public let lens0:Quaternion
    public let clockID:String
    public let headReferenceID:String
    public let bodyReferenceID:String
    public init(head0:TimedRotation,lens0:TimedRotation,body0:TimedRotation,headReferenceToWorld:Quaternion) throws {
        guard head0.clockID == body0.clockID,lens0.clockID == body0.clockID else { throw CompensationError.clockMismatch }
        guard abs(head0.measuredAt-body0.measuredAt) <= 1e-6,abs(lens0.measuredAt-body0.measuredAt) <= 1e-6 else { throw CompensationError.unbracketed }
        guard lens0.referenceID == body0.referenceID else { throw CompensationError.referenceChanged }
        guard head0.quality != .receiptTimeOnly,lens0.quality != .receiptTimeOnly,body0.quality != .receiptTimeOnly else { throw CompensationError.unobservableBody }
        self.head0=try head0.rotation.normalized(); self.lens0=try lens0.rotation.normalized()
        self.headReferenceToWorld=try headReferenceToWorld.normalized()
        clockID=head0.clockID; headReferenceID=head0.referenceID; bodyReferenceID=body0.referenceID
    }
    public func target(_ pair:AlignedRotations) throws -> (world:Quaternion,body:Quaternion) {
        guard pair.head.clockID == clockID,pair.body.clockID == clockID else { throw CompensationError.clockMismatch }
        guard pair.head.referenceID == headReferenceID,pair.body.referenceID == bodyReferenceID else { throw CompensationError.referenceChanged }
        guard pair.head.quality != .receiptTimeOnly,pair.body.quality != .receiptTimeOnly else { throw CompensationError.unobservableBody }
        let h=try pair.head.rotation.normalized(),b=try pair.body.rotation.normalized()
        let raw=try (headReferenceToWorld*h*head0.inverse*headReferenceToWorld.inverse*lens0).normalized()
        let world=try levelOpticalAxis(raw)
        return (world,try (b.inverse*world).normalized())
    }
    public static func deriveBody(worldFromLens:TimedRotation,bodyFromLens:TimedRotation) throws -> TimedRotation {
        guard worldFromLens.quality != .receiptTimeOnly,bodyFromLens.quality != .receiptTimeOnly else { throw CompensationError.unobservableBody }
        guard worldFromLens.clockID == bodyFromLens.clockID else { throw CompensationError.clockMismatch }
        guard abs(worldFromLens.measuredAt-bodyFromLens.measuredAt) <= 1e-6 else { throw CompensationError.unbracketed }
        // Requires COMPLETE measured R_BL, not yaw plus a second copy of world tilt.
        let result=try (worldFromLens.rotation.normalized()*bodyFromLens.rotation.normalized().inverse).normalized()
        return .init(result,at:worldFromLens.measuredAt,receivedAt:max(worldFromLens.receivedAt,bodyFromLens.receivedAt),clock:worldFromLens.clockID,reference:worldFromLens.referenceID,quality:.derivedFromCompleteMeasuredRotations)
    }
}

/// Ideal two-axis joint model ONLY. This is NOT qualified Pocket kinematics.
public func idealProjection(_ bodyFromLens:Quaternion,previousYaw:Double,limits:VerifiedLimits) throws -> (raw:Angles,limited:Angles) {
    let n=try bodyFromLens.rotate(.init(x:0,y:1,z:0))
    guard hypot(n.x,n.y) > sin(3 * .pi/180) else { throw CompensationError.unreachable }
    let raw=Angles(yaw:Orientation.unwrap(atan2(n.x,n.y)*180 / .pi,near:previousYaw),pitch:atan2(n.z,hypot(n.x,n.y))*180 / .pi)
    return (raw,limits.clamp(raw))
}

/// Keep the target optical ray; remove head roll using world gravity.
public func levelOpticalAxis(_ rotation:Quaternion) throws -> Quaternion {
    let n=try rotation.rotate(.init(x:0,y:1,z:0))
    guard hypot(n.x,n.y) > sin(3 * .pi/180) else { throw CompensationError.unreachable }
    let r=try n.cross(.init(x:0,y:0,z:1)).unit(),u=try r.cross(n).unit()
    let m00=r.x,m01=n.x,m02=u.x,m10=r.y,m11=n.y,m12=u.y,m20=r.z,m21=n.z,m22=u.z
    let trace=m00+m11+m22
    let q:Quaternion
    if trace > 0 {
        let s=2*sqrt(trace+1); q = .init(w:s/4,x:(m21-m12)/s,y:(m02-m20)/s,z:(m10-m01)/s)
    } else if m00 > m11 && m00 > m22 {
        let s=2*sqrt(1+m00-m11-m22);q = .init(w:(m21-m12)/s,x:s/4,y:(m01+m10)/s,z:(m02+m20)/s)
    } else if m11 > m22 {
        let s=2*sqrt(1+m11-m00-m22);q = .init(w:(m02-m20)/s,x:(m01+m10)/s,y:s/4,z:(m12+m21)/s)
    } else {
        let s=2*sqrt(1+m22-m00-m11);q = .init(w:(m10-m01)/s,x:(m02+m20)/s,y:(m12+m21)/s,z:s/4)
    }
    return try q.normalized()
}
