import XCTest
@testable import HeadLink

@MainActor final class ForegroundCameraRecoveryTests:XCTestCase {
    @MainActor final class Harness {
        let recovery=ForegroundCameraRecovery()
        var path=true
        var ssid="ORIGINAL"
        var events:[String]=[],order:[String]=[]
        var activated=0,discarded=0,opened=0
        var hold:CheckedContinuation<Void,Never>?
        var suspendOpen=false
        var actions:ForegroundCameraRecovery.Actions {
            .init(pathReady:{self.path},openIdentity:{
                self.opened += 1; self.order.append("open_identity_only")
                if self.suspendOpen { await withCheckedContinuation { self.hold=$0 } }
            },readSSID:{self.order.append("read_real_identity"); return self.ssid},
            activate:{self.activated += 1; self.order.append("register_and_preview")},
            discard:{self.discarded += 1},event:{self.events.append($0)})
        }
        func drain() async { for _ in 0..<20 { await Task.yield() } }
    }
    func testSameCameraResumesOnlyAfterIdentityAndNeverRepeatsWithinEpoch() async {
        let h=Harness()
        h.recovery.start(expectedSSID:"ORIGINAL",actions:h.actions)
        h.recovery.start(expectedSSID:"ORIGINAL",actions:h.actions)
        await h.drain()
        XCTAssertEqual(h.order,["open_identity_only","read_real_identity","register_and_preview"])
        XCTAssertEqual(h.activated,1)
        XCTAssertEqual(h.events.last,"restored_no_motion")
        h.recovery.start(expectedSSID:"ORIGINAL",actions:h.actions); await h.drain()
        XCTAssertEqual(h.opened,1)
    }
    func testSubnetAbsenceAndWrongCameraCannotActivate() async {
        let h=Harness(); h.path=false
        h.recovery.start(expectedSSID:"ORIGINAL",actions:h.actions)
        XCTAssertEqual(h.events.last,"wifi_required"); XCTAssertEqual(h.opened,0)
        h.path=true; h.ssid="OTHER"; h.recovery.arm()
        h.recovery.start(expectedSSID:"ORIGINAL",actions:h.actions); await h.drain()
        XCTAssertEqual(h.activated,0); XCTAssertEqual(h.discarded,1)
        XCTAssertEqual(h.events.last,"wrong_camera")
    }
    func testBackgroundCancellationCannotRegisterLateEndpoint() async {
        let h=Harness(); h.suspendOpen=true
        h.recovery.start(expectedSSID:"ORIGINAL",actions:h.actions)
        await h.drain(); XCTAssertNotNil(h.hold)
        h.recovery.cancel(); h.hold?.resume(); h.hold=nil
        await h.drain()
        XCTAssertEqual(h.activated,0)
        XCTAssertFalse(h.events.contains("restored_no_motion"))
    }
    func testRecoveryDeadlineIsBoundedAndNeverReenters() async throws {
        let h=Harness(); h.suspendOpen=true
        h.recovery.start(expectedSSID:"ORIGINAL",actions:h.actions,deadline:.milliseconds(20))
        try await Task.sleep(for:.milliseconds(60))
        XCTAssertFalse(h.recovery.running); XCTAssertEqual(h.discarded,1)
        XCTAssertEqual(h.events.last,"timeout_20s")
        h.hold?.resume(); h.hold=nil; await h.drain()
        XCTAssertEqual(h.activated,0)
        h.recovery.start(expectedSSID:"ORIGINAL",actions:h.actions); await h.drain()
        XCTAssertEqual(h.opened,1)
    }
    func testImmediateCancellationCannotOpenAnEndpointLater() async {
        let h=Harness()
        h.recovery.start(expectedSSID:"ORIGINAL",actions:h.actions)
        h.recovery.cancel()
        await h.drain()
        XCTAssertEqual(h.opened,0)
        XCTAssertEqual(h.activated,0)
    }

}
