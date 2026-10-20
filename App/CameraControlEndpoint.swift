import Foundation
import OpenCineDJI
import OpenCineDJIApple

/// The existing target transport, separated for deterministic App-model regression tests.
/// Production always uses the same DjiAppleDatalink instance as preview and recording.
@MainActor protocol CameraControlEndpoint:AnyObject {
    var isFlowHealthy:Bool { get }
    func beginNativeTargets(token:UInt64)
    func noteNativeTarget(_ frame:Duml.Frame,token:UInt64) -> Bool
    func endNativeTargets(token:UInt64)
    @discardableResult func send(_ frame:Duml.Frame) -> UInt16
}
extension DjiAppleDatalink:CameraControlEndpoint {}
