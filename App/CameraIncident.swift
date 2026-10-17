import Foundation
import Network
import OpenCineDJIApple
import HeadLinkCore

struct NetworkDiagnostic:Codable {
    let observedAt:Double
    let defaultPathStatus:String
    let defaultPathUsesWiFi:Bool?
    let wifiInterfaceAvailable:Bool?
    let cameraSubnetPresent:Bool
    let ssidObservation:String
}

/// Default route and camera-subnet presence are separate facts. Neither proves the SSID.
@MainActor final class CameraNetworkObserver {
    private var monitor:NWPathMonitor?
    private var generation=0
    private var status="not_observed"
    private var wifi:Bool?
    private var available:Bool?
    private var cached:NetworkDiagnostic?
    func start() {
        guard monitor == nil else { return }
        generation += 1
        let epoch=generation,watch=NWPathMonitor()
        watch.pathUpdateHandler={ [weak self] path in
            let value:String
            switch path.status {
            case .satisfied:value="satisfied"
            case .unsatisfied:value="unsatisfied"
            case .requiresConnection:value="requires_connection"
            @unknown default:value="unknown"
            }
            let uses=path.usesInterfaceType(.wifi),has=path.availableInterfaces.contains{$0.type == .wifi}
            Task { @MainActor [weak self] in
                guard let self,self.generation == epoch else { return }
                self.status=value; self.wifi=uses; self.available=has; self.cached=nil
            }
        }
        monitor=watch; watch.start(queue:DispatchQueue(label:"org.headlink.network-observation"))
    }
    func snapshot(at time:Double) -> NetworkDiagnostic {
        if let cached,time >= cached.observedAt,time-cached.observedAt < 0.25 { return cached }
        let value=NetworkDiagnostic(observedAt:time,defaultPathStatus:status,defaultPathUsesWiFi:wifi,
            wifiInterfaceAvailable:available,cameraSubnetPresent:DjiAppleWiFiJoiner.isCameraPathReady(),
            ssidObservation:"unavailable_no_ssid_entitlement; subnet_presence_is_not_association_proof")
        cached=value; return value
    }
}

struct CameraAttitudeObservation:Codable {
    let receivedAt:Double
    let payloadHex:String
    let quaternionWorldToCamera:Quaternion?
    let interpretation:String
    // No camera sensor timestamp or independently measured body attitude is available.
}

struct CameraIncidentSample:Codable {
    let uptime:Double; let scenario:String; let scene:String
    let network:NetworkDiagnostic; let session:CameraHealthEvidence; let classification:String
    let connectionEpoch:UInt64; let followingState:String; let calibrationID:UInt64; let hasCalibration:Bool
    let calibrationInvalidation:CalibrationInvalidation?; let startRejection:TrackingStartRejection?
    let headAt:Double?; let headSensorTime:Double?; let headQuaternion:Quaternion?; let headTarget:Angles?
    let rawTarget:Angles?; let sentTarget:Angles?; let sentNativePitch:Double?
    let actualAngles:Angles?; let actualNativePitch:Double?; let poseAt:Double?; let cameraAttitude:CameraAttitudeObservation?
    let mode:String; let statusAt:Double?; let parameterAt:Double?
    let nativeWrites:Int; let targetSubmissions:Int; let commandIssue:String?; let lastTrackedCommandWriteLanded:Bool?
    let lastSocketErrorCode:Int?; let stopAttemptAt:Double?
    let actualRecording:Bool?; let recordingAt:Double?; let recordPending:Bool?; let recordError:String?
    let video:VideoPipelineSample; let videoRecoveryState:String; let videoRecoveryReason:String
    let lastAcceptedSampleAt:Double?; let sceneOrSessionEvent:String?
    let bodyAttitudeObservation:String
}
