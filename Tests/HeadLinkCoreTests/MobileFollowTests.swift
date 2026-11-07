import Foundation
import Testing
import OpenCineDJI
@testable import HeadLinkCore

struct MobileFollowTests {
    private let limits=FormalFollowProfile.limits(model:"Osmo Pocket 4",reportedFirmware:nil)!
    private func head(_ yaw:Double,_ t:Double,sensor:Double?=nil,pitch:Double=0) -> MotionSample {
        let q=Quaternion.axis(0,0,1,degrees:-yaw)*Quaternion.axis(1,0,0,degrees:pitch)
        return .init(attitude:q,receivedAt:t,sensorTime:sensor ?? t,rotationRate:0,
            gravity:try? q.inverse.rotate(.init(x:0,y:0,z:-1)))
    }
    private func lens(_ yaw:Double,_ t:Double,pitch:Double=0) -> CameraPose {
        .init(angles:.init(yaw:yaw,pitch:pitch),nativePitch:Orientation.wrap(180-pitch),receivedAt:t)
    }
    @Test func recenterAndStationaryHeadDoNotFightBodyFollow() throws {
        var m=MobileFollow();try m.start(sample:head(0,1),pose:lens(10,1),at:1)
        for i in 1...80 {
            let t=1+Double(i)*0.025
            let d=m.tick(head:head(0,t),pose:lens(10+Double(i)*0.25,t,pitch:Double(i)*0.1),limits:limits,axes:.both,response:.immediate,at:t)
            #expect(d == .idle)
        }
        #expect(m.running && m.hold == nil)
    }
    @Test func wrapAndAccelerationAtStartRemainContinuous() throws {
        var m=MobileFollow();try m.start(sample:head(178,1),pose:lens(5,1),at:1)
        var actual=5.0
        for i in 1...16 {
            let t=1+Double(i)*0.025
            let y=Orientation.wrap(178+Double(i)*0.7)
            let d=m.tick(head:head(y,t),pose:lens(actual,t),limits:limits,axes:.both,response:.immediate,at:t)
            guard case let .target(target,_,expires)=d else { Issue.record("Expected a bounded target"); return }
            #expect(abs(target.yaw-actual) <= 3.0001)
            if i == 1 { #expect(abs(target.yaw-actual) <= 0.451) }
            #expect(expires == t+0.2)
            actual=target.yaw
        }
        #expect(actual > 10 && actual < 18 && m.hold == nil)
    }
    @Test func boundaryDiscardsAccumulatedInputAndOtherAxisStillMoves() throws {
        var m=MobileFollow();try m.start(sample:head(0,1),pose:lens(222,1),at:1)
        var actual=Angles(yaw:222,pitch:0)
        var t=1.0
        for i in 1...100 {
            t+=0.025
            let p=lens(actual.yaw,t,pitch:actual.pitch)
            let d=m.tick(head:head(Double(i)*0.8,t,pitch:Double(i)*0.1),pose:p,limits:limits,axes:.both,response:.smooth,at:t)
            if case let .target(a,_,_)=d { #expect(limits.clamp(a) == a);actual=a }
        }
        #expect(m.running && m.limited)
        #expect(actual.yaw > 224.8 && actual.pitch > 8)
        for i in 1...8 {
            t+=0.025
            let p=lens(actual.yaw,t,pitch:actual.pitch)
            let d=m.tick(head:head(80-Double(i)*0.8,t,pitch:10),pose:p,limits:limits,axes:.both,response:.smooth,at:t)
            if case let .target(a,_,_)=d { actual=a }
        }
        #expect(actual.yaw < 223 && m.running)
        #expect(!m.limited)
    }
    @Test func transientMissingHeadOrLensDoesNotCatchUpOrResetReference() throws {
        for reason in [MobileHold.headStale,.cameraStale] {
            var m=MobileFollow();try m.start(sample:head(0,1),pose:lens(0,1),at:1)
            let fault=m.tick(head:reason == .headStale ? nil : head(0,1.25),pose:reason == .cameraStale ? nil : lens(5,1.25),limits:limits,axes:.both,response:.immediate,at:1.25)
            #expect(fault == .stop && m.running && m.hold == reason)
            let recovered=m.tick(head:head(15,1.35),pose:lens(20,1.35),limits:limits,axes:.both,response:.immediate,at:1.35)
            #expect(recovered == .idle && m.hold == nil && m.reference != nil)
            let first=m.tick(head:head(16,1.375),pose:lens(20,1.375),limits:limits,axes:.both,response:.immediate,at:1.375)
            guard case let .target(a,_,_)=first else { Issue.record("Expected new small demand");return }
            #expect(a.yaw > 20 && a.yaw < 20.5)
        }
    }
    @Test func realReferenceLossOrLongGapCannotAutoStart() throws {
        var m=MobileFollow();try m.start(sample:head(0,1),pose:lens(0,1),at:1)
        let reset=m.tick(head:head(0,1.1,sensor:0.5),pose:lens(0,1.1),limits:limits,axes:.both,response:.immediate,at:1.1)
        #expect(reset == .referenceLost && m.reference == nil && !m.running)
        try m.start(sample:head(0,2),pose:lens(0,2),at:2)
        _=m.tick(head:nil,pose:lens(0,2.3),limits:limits,axes:.both,response:.immediate,at:2.3)
        _=m.tick(head:nil,pose:lens(0,3.4),limits:limits,axes:.both,response:.immediate,at:3.4)
        let later=m.tick(head:head(10,3.5),pose:lens(20,3.5),limits:limits,axes:.both,response:.immediate,at:3.5)
        #expect(later == .idle && !m.running)
    }
    @Test func commandRetryIsBoundedAndPauseCannotResume() throws {
        var m=MobileFollow();try m.start(sample:head(0,1),pose:lens(0,1),at:1)
        let first=m.interrupt(.command,at:1.1)
        #expect(first)
        let recovery=m.tick(head:head(1,1.4),pose:lens(2,1.4),limits:limits,axes:.both,response:.immediate,at:1.4)
        #expect(recovery == .idle && m.running && m.hold == nil)
        let second=m.interrupt(.command,at:1.5)
        #expect(second)
        #expect(!m.running)
        m.pause()
        let later=m.tick(head:head(2,1.6),pose:lens(2,1.6),limits:limits,axes:.both,response:.immediate,at:1.6)
        #expect(later == .idle)
    }
    @Test func udpDeadlineAndRetiredOwnershipDropQueuedTargets() throws {
        let frame=try #require(Commands.gimbalTimedTarget(yawDeg:20,nativePitchDeg:180,duration:0.1))
        var q=GimbalNativeTargetStream();q.begin(token:1)
        let value96=q.submit(frame,token:1,now:10,deadline:10.01)
        #expect(value96)
        let value97=q.next(now:10.009,connectionReady:false)
        #expect(value97 == nil)
        let value98=q.next(now:10.02)
        #expect(value98 == nil)
        let value99=q.submit(frame,token:1,now:10.03,deadline:10.1)
        #expect(value99)
        let value100=q.cancel(token:1)
        #expect(value100)
        q.begin(token:2)
        let value102=q.submit(frame,token:1,now:10.04,deadline:10.1)
        #expect(!value102)
        let value103=q.next(now:10.05)
        #expect(value103 == nil)
    }
}
