import Testing
import Foundation
@testable import HeadLinkCore
import OpenCineDJI

struct RangeBehaviorTests {
    struct Run {
        var c=TrackingController(),time=0.0,actual=Angles.zero,head=Angles.zero
        var feedback=FollowFeedbackMonitor()
        init(response:ResponseMode = .immediate) throws {
            c.limits=FormalFollowProfile.limits(model:"Osmo Pocket 4",reportedFirmware:nil)
            c.response=response; c.connectionChanged(true)
            feed(); try c.beginCalibration(at:time)
            for _ in 0..<35 { feed(); if c.state == .calibrating { _=try c.collectCalibration(at:time) } }
            try c.start(at:time); _=try tick()
        }
        mutating func feed(camera:Bool = true) {
            time += 0.025
            c.ingest(.init(attitude:.axis(0,0,1,degrees:-head.yaw) * .axis(1,0,0,degrees:head.pitch),receivedAt:time,sensorTime:time,rotationRate:0))
            if camera { c.ingest(.init(angles:actual,nativePitch:Orientation.wrap(-actual.pitch),receivedAt:time)) }
        }
        mutating func tick() throws -> TrackingOutput {
            feed()
            let value=c.tick(at:time)
            let out=try #require(value)
            #expect(out.limited == c.limits!.clamp(out.raw))
            #expect(c.limits!.clamp(out.command) == out.command)
            #expect(Commands.gimbalTimedTarget(yawDeg:out.command.yaw,nativePitchDeg:out.nativePitch,duration:0.1) != nil)
            let check=feedback.update(command:out.command,nativePitch:out.nativePitch,transitioning:out.transitioning,pose:c.pose,at:time)
            #expect(check.state != .diverged)
            actual=out.command
            return out
        }
        @discardableResult mutating func move(_ target:Angles,hold:Int = 60) throws -> TrackingOutput {
            let from=head,n=max(1,Int(ceil(max(abs(target.yaw-from.yaw),abs(target.pitch-from.pitch)))))
            var out:TrackingOutput?
            for i in 1...n {
                let f=Double(i)/Double(n)
                head = .init(yaw:from.yaw+(target.yaw-from.yaw)*f,pitch:from.pitch+(target.pitch-from.pitch)*f)
                out=try tick()
            }
            for _ in 0..<hold { out=try tick() }
            return try #require(out)
        }
    }
    @Test func fourBoundariesReturnWithoutWindupAndOtherAxisContinues() throws {
        var r=try Run();let id=r.c.calibrationID
        for _ in 0..<3 {
            for target in [Angles(yaw:-60,pitch:0),.init(yaw:-80,pitch:20),.init(yaw:-50,pitch:-55),
                           .init(yaw:-20,pitch:0),.init(yaw:240,pitch:80),.init(yaw:230,pitch:75),.init(yaw:210,pitch:60),.zero] {
                let o=try r.move(target)
                #expect(abs(o.raw.yaw-target.yaw)+abs(o.raw.pitch-target.pitch) < 1e-7)
                let limit=r.c.limits!.clamp(target)
                #expect(abs(o.command.yaw-limit.yaw)+abs(o.command.pitch-limit.pitch) < 0.001)
                #expect(r.c.hasCalibration && r.c.calibrationID == id && r.c.state == .following)
                #expect(r.feedback.reading?.state == .withinTolerance)
            }
            #expect(abs(r.actual.yaw)+abs(r.actual.pitch) < 1e-7)
        }
    }
    @Test func smoothingConvergesToOriginalMappingAfterRepeatedLimits() throws {
        var r=try Run(response:.smooth)
        for _ in 0..<3 {
            let edge=try r.move(.init(yaw:-70,pitch:80),hold:180)
            #expect(edge.limitedByRange && abs(edge.command.yaw+48) < 0.01 && abs(edge.command.pitch-70) < 0.01)
            let back=try r.move(.zero,hold:180)
            #expect(!back.limitedByRange && abs(back.command.yaw)+abs(back.command.pitch) < 0.01)
        }
    }
    @Test func pauseAtLimitCannotResumeFromHeadReturning() throws {
        var r=try Run();try r.move(.init(yaw:-65,pitch:20));let id=r.c.calibrationID
        r.c.pause()
        for i in 1...70 { r.head.yaw=min(0,-65+Double(i)); r.feed(); #expect(r.c.tick(at:r.time) == nil) }
        #expect(r.c.state == .userPaused && r.c.hasCalibration && r.c.calibrationID == id)
    }
    @Test func staleHeadCameraReferenceChangeAndRealDisconnectStillInvalidate() throws {
        for failure in 0..<4 {
            var r=try Run();try r.move(.init(yaw:-65,pitch:10))
            if failure == 0 { r.time += 0.31; #expect(r.c.tick(at:r.time) == nil) }
            if failure == 1 { for _ in 0..<14 { r.feed(camera:false); _=r.c.tick(at:r.time) } }
            if failure == 2 { r.head.yaw=100; r.feed(); _=r.c.tick(at:r.time) }
            if failure == 3 { r.c.connectionChanged(false); r.c.connectionChanged(true) }
            #expect(!r.c.hasCalibration && r.c.state != .following)
            r.head = .zero; r.feed(); #expect(r.c.tick(at:r.time) == nil)
        }
    }
    @Test func crossingRepresentationBoundaryIsContinuousAndFeedbackUsesExecutableTarget() throws {
        var r=try Run();try r.move(.init(yaw:175,pitch:0))
        var previous=r.actual.yaw
        for d in 176...240 {
            r.head.yaw=Double(d); let out=try r.tick()
            #expect(abs(out.command.yaw-previous) < 1.001)
            previous=out.command.yaw
        }
        #expect(previous == 225)
        for _ in 0..<100 { let o=try r.tick(); #expect(o.raw.yaw > 225 && o.command.yaw == 225) }
        #expect(r.feedback.reading?.state == .withinTolerance)
        #expect(r.c.hasCalibration)
    }
}
