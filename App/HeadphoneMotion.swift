import CoreMotion
import Foundation
import HeadLinkCore

protocol HeadphoneMotionService:AnyObject {
    var available:Bool { get }
    var active:Bool { get }
    var authorization:CMAuthorizationStatus { get }
    var diagnostic:MotionDeliveryDiagnostic { get }
    func start()
    func stop()
    func read() -> MotionReading
}

/// Sensor callback runs off the UI queue. A single lock-protected slot prevents callback backlog.
final class HeadphoneMotion: NSObject, HeadphoneMotionService, CMHeadphoneMotionManagerDelegate, @unchecked Sendable {
    private let manager=CMHeadphoneMotionManager()
    private let queue: OperationQueue = { let q=OperationQueue(); q.name="HeadLink.motion"; q.maxConcurrentOperationCount=1; q.qualityOfService = .userInteractive; return q }()
    private let lock=NSLock()
    private var delivery=MotionDelivery()
    private var generation: UInt64=0
    private var callbackToken:UInt64=0
    private var routeDown=false
    override init() { super.init(); manager.delegate=self }
    func headphoneMotionManagerDidConnect(_ manager:CMHeadphoneMotionManager) {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1; delivery = .init(); routeDown=false
    }
    func headphoneMotionManagerDidDisconnect(_ manager:CMHeadphoneMotionManager) {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1; delivery = .init(); routeDown=true
    }
    var active:Bool { manager.isDeviceMotionActive }
    var available: Bool { manager.isDeviceMotionAvailable }
    var authorization: CMAuthorizationStatus { CMHeadphoneMotionManager.authorizationStatus() }
    func start() {
        guard !manager.isDeviceMotionActive,available else { return }
        lock.lock(); delivery = .init(); generation &+= 1; callbackToken &+= 1; routeDown=false; let token=callbackToken; lock.unlock()
        manager.startDeviceMotionUpdates(to:queue) { [weak self] motion,error in
            guard let self else { return }
            let t=ProcessInfo.processInfo.systemUptime
            lock.lock(); defer { lock.unlock() }
            guard callbackToken == token,!routeDown else { return }
            guard error == nil,let motion else { delivery.accept(nil,at:t); return }
            let q=motion.attitude.quaternion, r=motion.rotationRate,g=motion.gravity
            delivery.accept(.init(attitude:.init(w:q.w,x:q.x,y:q.y,z:q.z),receivedAt:t,sensorTime:motion.timestamp,
                rotationRate:sqrt(r.x*r.x+r.y*r.y+r.z*r.z),gravity:.init(x:g.x,y:g.y,z:g.z)),at:t)
        }
    }
    func read() -> MotionReading {
        lock.lock(); defer { lock.unlock() }
        let value=delivery.reading(at:ProcessInfo.processInfo.systemUptime)
        return .init(sample:value.sample,callbackHz:value.callbackHz,failed:value.failed,sourceErrorCount:value.sourceErrorCount,sourceGeneration:generation)
    }
    var diagnostic:MotionDeliveryDiagnostic { lock.lock(); defer { lock.unlock() }; var value=delivery.diagnostic; value.generation=generation; return value }
    func stop() { manager.stopDeviceMotionUpdates(); lock.lock(); generation &+= 1; callbackToken &+= 1; delivery = .init(); lock.unlock() }
    deinit { manager.stopDeviceMotionUpdates() }
}
