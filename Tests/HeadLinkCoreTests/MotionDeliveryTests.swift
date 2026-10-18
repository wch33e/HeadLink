import Testing
@testable import HeadLinkCore

struct MotionDeliveryTests {
    func sample(_ time:Double) -> MotionSample { .init(attitude:.identity,receivedAt:time,sensorTime:time,rotationRate:0) }
    @Test func errorRemainsHistoricalAfterAnActualSuccessfulCallback() {
        var source=MotionDelivery()
        source.accept(sample(1),at:1)
        source.accept(nil,at:1.025)
        #expect(source.reading(at:1.025).failed)
        #expect(source.reading(at:1.025).sample == nil)
        source.accept(sample(1.05),at:1.05)
        #expect(!source.reading(at:1.05).failed)
        #expect(source.reading(at:1.05).sourceErrorCount == 1)
        #expect(source.reading(at:1.05).sample?.receivedAt == 1.05)
        #expect(source.diagnostic.errors == 1)
        #expect(source.diagnostic.lastErrorAt == 1.025 && source.diagnostic.lastRecoveryAt == 1.05)
    }
    @Test func callbacksKeepTheirTimesWhenTheConsumerIsDelayed() {
        var source=MotionDelivery()
        for i in 0...30 { let t=1+Double(i)*0.02; source.accept(sample(t),at:t) }
        #expect(source.diagnostic.callbacks == 31)
        #expect(source.diagnostic.maximumCallbackGap < 0.021)
        #expect(source.reading(at:1.61).sample?.receivedAt == 1.6)
        #expect(source.reading(at:2).callbackHz == 0)
        #expect(source.reading(at:2).sample?.receivedAt == 1.6) // Never re-stamp an old sample.
    }
}
