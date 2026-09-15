// Link state with prediction: the latest pose, timestamped, extrapolated to "now".
import Foundation
import simd

public final class LinkState {
    private let lock = NSLock()
    private var last: (pose: Pose, at: TimeInterval)?
    private var prev: (pose: Pose, at: TimeInterval)?
    public private(set) var roster: [Int] = []
    public private(set) var track: Int = -1
    public private(set) var packets = 0
    public var maxPrediction: TimeInterval = 0.25
    /// Faithful mode: no extrapolation, the last packet is held until the next (what the pod does).
    public var hold = false

    public init() {}

    public func accept(_ packet: LinkPacket, at t: TimeInterval = Date().timeIntervalSinceReferenceDate) {
        lock.lock(); defer { lock.unlock() }
        packets += 1
        switch packet {
        case .roster(let tr, let models): track = tr; roster = models
        case .pose(let p): prev = last; last = (p, t)
        default: break
        }
    }

    /// The pose as it was last received, and how long ago.
    public func latest() -> (Pose, TimeInterval)? {
        lock.lock(); defer { lock.unlock() }
        guard let l = last else { return nil }
        return (l.pose, Date().timeIntervalSinceReferenceDate - l.at)
    }

    /// Position extrapolated along the velocity of the last two packets (orientation held); `nil` before any pose.
    public func predicted(at t: TimeInterval = Date().timeIntervalSinceReferenceDate) -> Pose? {
        lock.lock(); defer { lock.unlock() }
        guard let l = last else { return nil }
        var p = l.pose
        if hold { return p }
        if let q = prev, l.at > q.at {
            let dt = min(max(t - l.at, 0), maxPrediction)
            let v = (l.pose.position - q.pose.position) / (l.at - q.at)
            let np = l.pose.position + v * dt
            p.x = Int32(np.x.rounded()); p.y = Int32(np.y.rounded()); p.z = Int32(np.z.rounded())
        }
        return p
    }
}
