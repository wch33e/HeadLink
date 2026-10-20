import Testing
@testable import HeadLinkCore

@Suite struct MotionRecoveryTests {
    @Test func lateHardwareAndActiveServiceWithoutSamples() {
        var p=MotionRecoveryPolicy()
        #expect(p.action(at:0,available:false,authorized:true,active:false,sampleAt:nil) == nil)
        #expect(p.attempts == 0)
        #expect(p.action(at:2,available:true,authorized:true,active:false,sampleAt:nil) == .start)
        #expect(p.action(at:2.1,available:true,authorized:true,active:true,sampleAt:nil) == nil)
        #expect(p.action(at:3.1,available:true,authorized:true,active:true,sampleAt:nil) == .restart)
        #expect(p.action(at:4.2,available:true,authorized:true,active:true,sampleAt:nil) == nil)
        #expect(p.action(at:6.2,available:true,authorized:true,active:true,sampleAt:nil) == .restart)
        #expect(p.action(at:100,available:true,authorized:true,active:false,sampleAt:nil) == nil)
        #expect(p.attempts == 3)
    }
    @Test func returningFreshDoesNotRestartAndPermissionDenialNeverRetries() {
        var p=MotionRecoveryPolicy()
        #expect(p.action(at:10,available:true,authorized:true,active:true,sampleAt:9.99) == nil)
        #expect(p.action(at:11,available:true,authorized:false,active:false,sampleAt:nil) == nil)
        #expect(p.attempts == 0)
        #expect(p.action(at:12,available:true,authorized:true,active:true,sampleAt:nil) == nil)
        #expect(p.action(at:12.5,available:true,authorized:true,active:true,sampleAt:nil) == nil)
        #expect(p.action(at:13.1,available:true,authorized:true,active:true,sampleAt:nil) == .restart)
        p.beginForeground()
        #expect(p.attempts == 0)
    }
}
