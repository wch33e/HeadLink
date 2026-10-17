import Testing
@testable import HeadLinkCore

struct CameraHealthTests {
    func evidence(_ t:Double,flow:Bool = false,control:Double? = nil,path:Bool = true,
                  rebuilding:Bool = false,closed:Bool = false) -> CameraHealthEvidence {
        .init(now:t,connected:true,endpointPresent:true,endpointClosed:closed,flowHealthy:flow,
              rebuilding:rebuilding,cameraSubnetPresent:path,controlAt:control,videoAt:nil)
    }
    @Test func freshInboundDoesNotTearDownOnWriteOrPathFlag() {
        var p=CameraSessionHealthPolicy()
        for i in 0...1200 {
            let t=Double(i)/4
            let e=evidence(t,control:t,path:false)
            #expect(p.disconnectReason(e) == nil)
            #expect(e.classification == "inbound_control_alive_outbound_unavailable")
        }
        #expect(p.unhealthySince == nil)
    }
    @Test func genuineLocalTransportLossRetainsBoundedDetection() {
        var p=CameraSessionHealthPolicy()
        #expect(p.disconnectReason(evidence(10,control:8,path:false)) == nil)
        #expect(p.disconnectReason(evidence(10.99,control:8,path:false)) == nil)
        #expect(p.disconnectReason(evidence(11,control:8,path:false)) == "camera_subnet_absent_transport_unavailable_1s")
    }
    @Test func freshTelemetryResetsTransientFailureAndFutureIsNotFresh() {
        var p=CameraSessionHealthPolicy()
        #expect(p.disconnectReason(evidence(0)) == nil)
        #expect(p.disconnectReason(evidence(0.9,control:0.9)) == nil)
        #expect(p.disconnectReason(evidence(2,control:0.9)) == nil)
        #expect(p.disconnectReason(evidence(3,control:4)) == "local_transport_unavailable_without_control_1s")
    }
    @Test func repairOwnsItsLifetimeAndClosedEndpointHasExactReason() {
        var p=CameraSessionHealthPolicy()
        #expect(p.disconnectReason(evidence(10,rebuilding:true)) == nil)
        #expect(p.disconnectReason(evidence(30,rebuilding:true)) == nil)
        #expect(p.disconnectReason(evidence(31,closed:true)) == "local_endpoint_closed")
    }
    @Test func videoLossIsIndependentFromControlSession() {
        var p=CameraSessionHealthPolicy()
        let e=evidence(12,flow:true,control:12)
        #expect(e.classification == "control_alive_video_ingress_stale")
        #expect(p.disconnectReason(e) == nil)
        // A healthy socket alone cannot prove that the remote camera is responding.
        #expect(evidence(13,flow:true).classification == "transport_ready_control_stale")
    }
    @Test func receivedVideoAlsoPreventsFalseGlobalDisconnectButDoesNotProveControl() {
        var p=CameraSessionHealthPolicy()
        for t in 0...300 {
            let e=CameraHealthEvidence(now:Double(t),connected:true,endpointPresent:true,endpointClosed:false,
                flowHealthy:false,rebuilding:false,cameraSubnetPresent:false,controlAt:nil,videoAt:Double(t))
            #expect(p.disconnectReason(e) == nil)
            #expect(e.classification == "video_ingress_alive_control_stale")
            #expect(!e.controlFresh)
        }
    }
    @Test func videoOnlyRepairPreservesCalibratedTrackingReferenceAndNeverAutoResumes() throws {
        var c=try TrackingTests().calibrated(),p=VideoRecoveryPolicy()
        let id=c.calibrationID
        try c.start(at:1.875)
        for i in 1...1200 {
            let t=1.875+Double(i)*0.025
            TrackingTests().feed(&c,at:t)
            let v=VideoPipelineSample(now:t,startedAt:0,connected:true,transportReady:true,packetAt:0,
                accessUnitAt:0,presentedAt:0,controlFrameAt:t)
            if let action=p.tick(v) {
                #expect(action != .rebuildSharedTransport)
                c.pause() // Same admission used by the App's video-repair callback.
            }
            #expect(c.hasCalibration && c.calibrationID == id)
            if t >= 4 { #expect(c.state == .userPaused && c.tick(at:t) == nil) }
        }
        #expect(c.startBlocker(at:31.875) == nil)
        try c.start(at:31.875) // Only the user's explicit action resumes.
        #expect(c.state == .following)
    }
    @Test func videoRepairCannotReplaceLiveControlForFiveMinutes() {
        var p=VideoRecoveryPolicy()
        func video(_ t:Double,control:Double?) -> VideoPipelineSample {
            .init(now:t,startedAt:0,connected:true,transportReady:true,packetAt:0,accessUnitAt:0,
                  presentedAt:0,controlFrameAt:control)
        }
        #expect(p.tick(video(4,control:4)) == .registerAndEnable)
        #expect(p.tick(video(8,control:8)) == .registerAndEnable)
        for t in 12...300 { #expect(p.tick(video(Double(t),control:Double(t))) == nil) }
        #expect(p.attempts == 2 && p.state == .stalled)
        // If both channels later fail, the one shared repair remains bounded and available.
        #expect(p.tick(video(304,control:300)) == .rebuildSharedTransport)
        #expect(p.attempts == 3)
        #expect(p.tick(video(308,control:300)) == nil && p.state == .failed)
    }
}
