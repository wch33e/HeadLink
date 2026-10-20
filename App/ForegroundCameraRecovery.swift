import Foundation

/// One finite, identity-checked recovery per background/foreground epoch.
/// All endpoint operations are the same native implementation used by initial connection.
@MainActor final class ForegroundCameraRecovery {
    struct Actions {
        var pathReady:()->Bool
        var openIdentity:() async throws -> Void
        var readSSID:() async throws -> String
        var activate:()->Void
        var discard:()->Void
        var event:(String)->Void
    }
    private(set) var attempted=false
    private var generation=0
    private var task:Task<Void,Never>?
    private var timeout:Task<Void,Never>?
    var running:Bool { task != nil }
    func arm() { cancel(); attempted=false }
    func cancel() { generation += 1; task?.cancel(); task=nil; timeout?.cancel(); timeout=nil }
    func start(expectedSSID:String,actions:Actions,deadline:Duration = .seconds(20)) {
        guard !attempted,task == nil else { return }
        attempted=true
        guard actions.pathReady() else { actions.event("wifi_required"); return }
        let epoch=generation
        actions.event("checking_original_camera")
        task=Task { [weak self] in
            guard let self else { return }
            do {
                try await actions.openIdentity()
                try Task.checkCancellation()
                guard generation == epoch else { return }
                let identity=try await actions.readSSID()
                try Task.checkCancellation()
                guard generation == epoch else { return }
                guard !expectedSSID.isEmpty,identity == expectedSSID else {
                    actions.discard(); finish(); actions.event("wrong_camera"); return
                }
                guard actions.pathReady() else { actions.discard(); finish(); actions.event("wifi_required"); return }
                actions.activate(); finish(); actions.event("restored_no_motion")
            } catch {
                guard generation == epoch else { return }
                actions.discard(); finish(); actions.event("communication_or_identity_failed")
            }
        }
        timeout=Task { [weak self] in
            do { try await Task.sleep(for:deadline) } catch { return }
            guard let self,generation == epoch,task != nil else { return }
            cancel(); actions.discard(); actions.event("timeout_20s")
        }
    }
    private func finish() { task=nil; timeout?.cancel(); timeout=nil }
}
