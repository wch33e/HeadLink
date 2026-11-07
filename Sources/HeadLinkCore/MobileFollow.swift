import Foundation

public enum MobileHold: String, Sendable {
    case headStale, cameraStale, transport, mode, path, command, feedback, scheduler, reference
}

/// Relative nudges in the Pocket protocol axes. This is neither a body estimator nor world lock.
/// Inputs are local monotonic receipts; the two devices' sensor clocks are never subtracted.
public struct MobileFollow: Sendable {
    public enum Decision: Equatable, Sendable { case idle, stop, referenceLost, target(Angles, nativePitch: Double, expiresAt: Double) }
    public private(set) var running = false
    public private(set) var reference: HeadDirectionReference?
    public private(set) var hold: MobileHold?
    public private(set) var limited = false
    public private(set) var goal: Angles?
    private var previous: MotionSample?
    private var look = Angles.zero
    public var headAngles:Angles? { reference == nil ? nil : look }
    private var deadband = Angles.zero
    private var filtered = Angles.zero
    private var command = Angles.zero
    private var velocity = Angles.zero
    private var tickAt: Double?
    private var holdAt: Double?
    private var quietAt: Double?
    private var released = true
    private var retryUsed = false
    private var lastDemandAt: Double?
    private var edgeDirection = Angles.zero
    public init() {}

    /// Recenter only the head reference; seed from the actual lens and emit no movement.
    public mutating func start(sample: MotionSample, pose: CameraPose, at now: Double) throws {
        guard sample.fresh(at: now, threshold: 0.2), sample.sensorTime.isFinite, pose.fresh(at: now) else { throw TrackingError.stale }
        guard let gravity = sample.gravity else { throw TrackingError.gravityUnavailable }
        let ref = try HeadDirectionReference(origin: sample.attitude, gravity: gravity)
        self = .init()
        reference = ref; previous = sample; running = true
        seed(pose, at: now)
    }

    public mutating func pause() {
        running = false; goal = nil; limited = false; velocity = .zero; released = true
    }

    public mutating func invalidateReference() {
        pause(); reference = nil; previous = nil; hold = .reference
    }

    /// A transient fault cancels the motion stream. Re-entry consumes current head and camera,
    /// not any missed movement. A second command rejection requires an explicit start.
    @discardableResult public mutating func interrupt(_ reason: MobileHold, at now: Double) -> Bool {
        guard running else { return false }
        if reason == .feedback || (reason == .command && retryUsed) || holdAt.map({now - $0 > 1}) == true {
            pause(); hold = reason; return true
        }
        if hold == reason { return false }
        if reason == .command { retryUsed = true }
        hold = reason; if holdAt == nil { holdAt = now }
        velocity = .zero; goal = nil; limited = false; released = true
        return true
    }

    public mutating func tick(head: MotionSample?, pose: CameraPose?, limits: VerifiedLimits,
                              axes: ControlAxes, response: ResponseMode, gain: Double = 1, reverseYaw: Bool = false, reversePitch: Bool = false, at now: Double) -> Decision {
        guard running, let reference else { return .idle }
        guard let head, head.fresh(at: now, threshold: 0.2) else { return interruption(.headStale, now) }
        guard head.sensorTime.isFinite,head.rotationRate.isFinite,head.rotationRate >= 0 else { return interruption(.reference, now) }
        let old = previous
        let nextLook: Angles
        do {
            if let old {
                let elapsed = head.receivedAt - old.receivedAt
                if elapsed < 0 || head.sensorTime < old.sensorTime || (elapsed > 0 && head.sensorTime == old.sensorTime) || (elapsed == 0 && head.sensorTime != old.sensorTime) {
                    invalidateReference(); return .referenceLost
                }
                if elapsed > 0 {
                    let distance = try head.attitude.distance(to: old.attitude)
                    // A long gap requires explicit start, not a claim that the reference jumped.
                    if elapsed > 1 { pause(); hold = .headStale; return .stop }
                    if distance > min(45, max(20, elapsed * 900)) {
                        invalidateReference(); return .referenceLost
                    }
                }
            }
            nextLook = try reference.look(head.attitude, previousYaw: look.yaw)
        } catch {
            return interruption(.reference, now)
        }
        previous = head
        guard let pose, pose.fresh(at: now) else { return interruption(.cameraStale, now) }
        guard limits.valid, limits.clamp(pose.angles) == pose.angles else { return interruption(.path, now) }
        if let reason = hold {
            let elapsed = now - (holdAt ?? now)
            if elapsed > 1 { pause(); hold = reason; return .stop }
            if (reason == .command || reason == .path) && elapsed < 0.2 { return .idle }
            look = nextLook; deadband = nextLook; hold = nil; holdAt = nil
            seed(pose, at: now); return .idle
        }
        let dt = now - (tickAt ?? now)
        if dt <= 0 { return .idle }
        if dt > 0.2 { return interruption(.scheduler, now) }
        tickAt = now
        look = nextLook
        // Hysteretic deadband (two 0.1-degree wire steps), not a per-sample cutoff.
        func consume(_ value: Double, _ anchor: inout Double) -> Double {
            let d = value - anchor
            let delta = abs(d) > 0.2 ? d - (d < 0 ? -0.2 : 0.2) : 0
            anchor += delta
            return delta
        }
        let yaw = consume(look.yaw, &deadband.yaw), pitch = consume(look.pitch, &deadband.pitch)
        let scale = gain.isFinite ? min(1,max(0.5,gain)) : 1
        let delta = Angles(yaw: axes == .pitch ? 0 : yaw * scale * (reverseYaw ? -1 : 1),
                           pitch: axes == .yaw ? 0 : pitch * scale * (reversePitch ? -1 : 1))
        if released {
            if delta == .zero {
                if edgeDirection.yaw != 0 {
                    let edge=edgeDirection.yaw < 0 ? limits.yawMin : limits.yawMax
                    if abs(pose.angles.yaw-edge) > 0.1 { edgeDirection.yaw=0 }
                }
                if edgeDirection.pitch != 0 {
                    let edge=edgeDirection.pitch < 0 ? limits.pitchMin : limits.pitchMax
                    if abs(pose.angles.pitch-edge) > 0.1 { edgeDirection.pitch=0 }
                }
                limited=edgeDirection != .zero
                return .idle
            }
            goal = pose.angles; command = pose.angles; filtered = pose.angles
            velocity = .zero; quietAt = nil; released = false
        }
        guard let oldGoal = goal else { return .idle }
        let raw = Angles(yaw: oldGoal.yaw + delta.yaw, pitch: oldGoal.pitch + delta.pitch)
        let bounded = limits.clamp(raw)
        if delta.yaw != 0 { edgeDirection.yaw = raw.yaw == bounded.yaw ? 0 : delta.yaw }
        if delta.pitch != 0 { edgeDirection.pitch = raw.pitch == bounded.pitch ? 0 : delta.pitch }
        limited = edgeDirection != .zero
        goal = bounded // Drop outward excess immediately. The next reverse increment can leave the edge.
        if delta != .zero { lastDemandAt = now }
        let alpha = response == .smooth ? 1 - exp(-dt / 0.04) : 1
        filtered.yaw += alpha * (bounded.yaw - filtered.yaw)
        filtered.pitch += alpha * (bounded.pitch - filtered.pitch)
        let next = limits.clamp(.init(yaw: Self.advance(command.yaw, filtered.yaw, dt, &velocity.yaw),
                                     pitch: Self.advance(command.pitch, filtered.pitch, dt, &velocity.pitch)))
        if next.yaw == limits.yawMin && velocity.yaw < 0 || next.yaw == limits.yawMax && velocity.yaw > 0 { velocity.yaw = 0 }
        if next.pitch == limits.pitchMin && velocity.pitch < 0 || next.pitch == limits.pitchMax && velocity.pitch > 0 { velocity.pitch = 0 }
        let settled = abs(next.yaw - bounded.yaw) + abs(next.pitch - bounded.pitch) < 0.05 &&
            abs(velocity.yaw) + abs(velocity.pitch) < 0.1
        if settled {
            if quietAt == nil { quietAt = now }
            if now - (quietAt ?? now) >= 0.1 {
                released = true; velocity = .zero
                return .idle // Do not send counter-corrections when DJI Follow is moving a resting lens.
            }
        } else { quietAt = nil }
        // Do not chase an obstructed or externally driven gimbal indefinitely after the head stops.
        if let lastDemandAt, now - lastDemandAt > 1.5 {
            released = true; velocity = .zero; return .stop
        }
        command = next
        let encodedYaw = (command.yaw * 10).rounded() / 10
        guard abs(encodedYaw - pose.angles.yaw) < 180 else { return interruption(.path, now) }
        let native = Orientation.wrap(pose.nativePitch - (command.pitch - pose.angles.pitch))
        return .target(command, nativePitch: native, expiresAt: head.receivedAt + 0.2)
    }

    private mutating func seed(_ pose: CameraPose, at now: Double) {
        goal = pose.angles; command = pose.angles; filtered = pose.angles
        velocity = .zero; tickAt = now; quietAt = nil; lastDemandAt = nil
        released = true; limited = false; edgeDirection = .zero
    }
    private mutating func interruption(_ reason: MobileHold, _ now: Double) -> Decision {
        if let holdAt, now - holdAt > 1 { pause(); hold = reason; return .stop }
        return interrupt(reason, at: now) ? .stop : .idle
    }
    private static func advance(_ current: Double, _ target: Double, _ dt: Double, _ velocity: inout Double) -> Double {
        let error = target - current, a = 720.0
        let desired = (error < 0 ? -1.0 : 1.0) * min(120, sqrt(2 * a * abs(error)))
        velocity += min(a * dt, max(-a * dt, desired - velocity))
        let step = velocity * dt
        if abs(velocity) <= a * dt && (abs(error) < 0.001 || (step * error >= 0 && abs(step) >= abs(error))) {
            velocity = 0; return target
        }
        return current + step
    }
}
