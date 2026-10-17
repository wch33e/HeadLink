import Testing
import HeadLinkCore
@testable import MovingBodyMath

struct WorldCompensationTests {
    func q(_ yaw:Double,_ pitch:Double = 0,_ roll:Double = 0) -> Quaternion {
        Quaternion.axis(0,0,1,degrees:-yaw)*Quaternion.axis(1,0,0,degrees:pitch)*Quaternion.axis(0,1,0,degrees:roll)
    }
    func pair(_ head:Quaternion,_ body:Quaternion,time:Double = 1) throws -> AlignedRotations {
        var h=RotationTimeline(),b=RotationTimeline()
        try h.append(.init(head,at:time)); try b.append(.init(body,at:time))
        return try .latest(head:h,body:b,now:time)
    }
    func solver() throws -> WorldCompensation {
        try .init(head0:.init(.identity,at:0),lens0:.init(.identity,at:0),body0:.init(.identity,at:0),headReferenceToWorld:.identity)
    }
    func near(_ a:Quaternion,_ b:Quaternion) throws {
        let x=try a.normalized(),y=try b.normalized(),sign=x.w*y.w+x.x*y.x+x.y*y.y+x.z*y.z < 0 ? -1.0 : 1.0
        let error=abs(x.w-sign*y.w)+abs(x.x-sign*y.x)+abs(x.y-sign*y.y)+abs(x.z-sign*y.z)
        #expect(error < 1e-10)
    }
    @Test func stationaryHeadWithRotatingBodyCancelsBodyMotion() throws {
        let c=try solver()
        for yaw in [-90.0,-30,0,30,90] {
            let result=try c.target(pair(.identity,q(yaw)))
            try near(result.body,q(-yaw)); try near(q(yaw)*result.body,.identity)
        }
    }
    @Test func headAndBodyTurnTogetherCannotDoubleTurn() throws {
        let c=try solver(),head=q(-30),body=q(-30)
        let result=try c.target(pair(head,body))
        try near(result.body,.identity); try near(body*result.body,head)
        #expect(try (body*q(-30)).distance(to:head) > 29)
    }
    @Test func fixedBodyRetainsOneToOneDirection() throws {
        let c=try solver()
        for angle in [-30.0,0,30] { let h=q(angle,angle/2),r=try c.target(pair(h,.identity)); try near(r.body,h) }
    }
    @Test func headAndBodyWithDifferentSimultaneousCompoundRotations() throws {
        let c=try solver()
        for i in 0...200 {
            let t=Double(i)/200,h=q(75*t,-30*t,15*t),b=q(-45*t,40*t,-35*t)
            let r=try c.target(pair(h,b)); try near(b*r.body,q(75*t,-30*t))
        }
    }
    @Test func translationDoesNotEnterDirectionTransform() throws {
        let c=try solver(),h=q(30,20),b=q(-40,15),r=try c.target(pair(h,b))
        // Arbitrary body positions are deliberately absent from the orientation function.
        for _ in [DirectionVector(x:0,y:0,z:0),.init(x:3,y:-8,z:1),.init(x:-2,y:5,z:-3)] {
            try near(c.target(pair(h,b)).body,r.body)
        }
    }
    @Test func differingHeadReferenceFramesComposeInTheCorrectOrder() throws {
        let align=q(53,17,-12),h0=q(13,8),l0=align*h0
        let c=try WorldCompensation(head0:.init(h0,at:0),lens0:.init(l0,at:0),body0:.init(.identity,at:0),headReferenceToWorld:align)
        let h=q(40,-10),b=q(-12,33,22),r=try c.target(pair(h,b))
        try near(b*r.body,levelOpticalAxis(align*h))
    }
    @Test func fullMeasuredLensAndJointRotationsRecoverBody() throws {
        let body=q(33,-24,47),joint=q(-26,37,-16),world=body*joint
        let derived=try WorldCompensation.deriveBody(worldFromLens:.init(world,at:1),bodyFromLens:.init(joint,at:1))
        try near(derived.rotation,body)
        #expect(derived.quality == .derivedFromCompleteMeasuredRotations)
    }
    @Test func observedLensAndPanAloneCannotDetermineRolledBody() throws {
        let bodyA=Quaternion.identity,bodyB=q(0,0,40)
        let jointA=Quaternion.identity,jointB=bodyB.inverse
        try near(bodyA*jointA,bodyB*jointB)
        #expect(try bodyA.distance(to:bodyB) > 39)
        // Both provide identical world lens attitude, pan=0 and optical elevation=0.
        // An independently MEASURED roll joint would disambiguate them; that is missing.
        let a=try idealProjection(jointA,previousYaw:0,limits:FormalFollowProfile.limits(model:"Osmo Pocket 4",reportedFirmware:nil)!)
        let b=try idealProjection(jointB,previousYaw:0,limits:FormalFollowProfile.limits(model:"Osmo Pocket 4",reportedFirmware:nil)!)
        #expect(abs(a.raw.yaw-b.raw.yaw) < 1e-8 && abs(a.raw.pitch-b.raw.pitch) < 1e-8)
    }
    @Test func hemisphereSignAndCrossing180RemainContinuous() throws {
        let a=q(179),end=q(181),negative=Quaternion(w:-end.w,x:-end.x,y:-end.y,z:-end.z)
        let mid=try slerp(a,negative,0.5); try near(mid,q(180))
        let limits=FormalFollowProfile.limits(model:"Osmo Pocket 4",reportedFirmware:nil)!
        var previous=170.0
        for d in stride(from:170.0,through:200,by:1) {
            let p=try idealProjection(q(d),previousYaw:previous,limits:limits)
            #expect(abs(p.raw.yaw-d) < 1e-8); previous=p.raw.yaw
        }
    }
    @Test func rangeLimitRecoveryDoesNotChangeCalibrationOrGain() throws {
        let limits=FormalFollowProfile.limits(model:"Osmo Pocket 4",reportedFirmware:nil)!
        var previous=220.0
        for d in [220.0,224,228,235,228,224,220] {
            let p=try idealProjection(q(d),previousYaw:previous,limits:limits); previous=p.raw.yaw
            #expect(abs(p.raw.yaw-d) < 1e-8 && abs(p.limited.yaw-min(d,225)) < 1e-8)
        }
    }
    @Test func head50HzAndBody100HzAreInterpolatedToOneCaptureTime() throws {
        var head=RotationTimeline(),body=RotationTimeline()
        for i in 0...10 { let t=Double(i)*0.02; try head.append(.init(q(t*60),at:t)) }
        for i in 0...19 { let t=Double(i)*0.01; try body.append(.init(q(t*30),at:t)) }
        let aligned=try AlignedRotations.latest(head:head,body:body,now:0.205)
        #expect(abs(aligned.time-0.19) < 1e-8)
        try near(aligned.head.rotation,q(11.4)); try near(aligned.body.rotation,q(5.7))
        let r=try solver().target(aligned); try near(r.body,q(5.7))
    }
    @Test func staleOrUnalignedDataCannotProduceCompensation() throws {
        var h=RotationTimeline(),b=RotationTimeline()
        try h.append(.init(.identity,at:1));try b.append(.init(.identity,at:1))
        #expect(throws:CompensationError.stale) { try AlignedRotations.latest(head:h,body:b,now:1.3) }
        var other=RotationTimeline();try other.append(.init(.identity,at:1,clock:"unknown-camera-clock"))
        #expect(throws:CompensationError.clockMismatch) { try AlignedRotations.latest(head:h,body:other,now:1) }
        #expect(throws:CompensationError.unbracketed) { try h.interpolate(at:1.01) }
        #expect(throws:CompensationError.unbracketed) { try WorldCompensation.deriveBody(worldFromLens:.init(.identity,at:1),bodyFromLens:.init(.identity,at:1.1)) }
    }
    @Test func packetReceiptIsNotAQualifiedSensorTimestamp() throws {
        var h=RotationTimeline(),b=RotationTimeline()
        try h.append(.init(.identity,at:1));try b.append(.init(.identity,at:1,quality:.receiptTimeOnly))
        #expect(throws:CompensationError.unobservableBody) { try AlignedRotations.latest(head:h,body:b,now:1) }
    }
    @Test func headRollCannotRollTheWorldTarget() throws {
        let c=try solver()
        for roll in [-80.0,-30,0,30,80] {
            let result=try c.target(pair(q(30,20,roll),q(-45,25,-20)))
            try near(result.world,q(30,20))
        }
    }
    @Test func referenceResetInvalidatesThePairAndCalibration() throws {
        var timeline=RotationTimeline(); try timeline.append(.init(.identity,at:1))
        let next=TimedRotation(.identity,at:1.02,reference:"new-reference")
        do { try timeline.append(next); Issue.record("reference reset accepted") } catch { #expect(error as? CompensationError == .referenceChanged) }
        let pair=try AlignedRotations(head:.init(.identity,at:1),body:next,time:1)
        #expect(throws:CompensationError.referenceChanged) { try solver().target(pair) }
    }
}
