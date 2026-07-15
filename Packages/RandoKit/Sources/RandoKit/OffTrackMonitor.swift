import Foundation

/// Debounced on/off-track state machine fed with one projection per GPS fix.
///
/// - The trigger distance grows with GPS uncertainty (`2 × accuracy`), so
///   degraded reception raises the bar instead of raising false alarms.
/// - Entering a new state requires the condition to persist for `dwell`
///   seconds, and leaving off-track uses a lower threshold than entering it
///   (hysteresis) — the indicator never flickers at the boundary.
public struct OffTrackMonitor: Equatable, Sendable {
    public enum Status: String, Equatable, Sendable {
        case unknown
        case approachingStart
        case onTrack
        case offTrack
        case finished
    }

    public var triggerDistance: Double
    public var clearDistance: Double
    public var dwell: TimeInterval

    public private(set) var status: Status = .unknown
    private var candidateStatus: Status?
    private var candidateSince: Date?

    public init(triggerDistance: Double = 50, clearDistance: Double = 30, dwell: TimeInterval = 20) {
        self.triggerDistance = triggerDistance
        self.clearDistance = clearDistance
        self.dwell = dwell
    }

    @discardableResult
    public mutating func update(
        projection: TraceProjection, horizontalAccuracy: Double, traceLength: Double,
        timestamp: Date
    ) -> Status {
        let trigger = max(triggerDistance, 2 * max(horizontalAccuracy, 0))
        let cross = projection.crossTrackDistance

        let raw: Status
        if cross <= clearDistance {
            raw = .onTrack
        } else if cross >= trigger {
            if projection.distanceAlong <= 0.5 {
                raw = .approachingStart
            } else if projection.distanceAlong >= traceLength - 0.5 {
                raw = .finished
            } else {
                raw = .offTrack
            }
        } else {
            // Hysteresis band between clear and trigger: keep the current state.
            raw = status == .unknown ? .onTrack : status
        }

        if status == .unknown {
            status = raw
            candidateStatus = nil
            candidateSince = nil
            return status
        }
        guard raw != status else {
            candidateStatus = nil
            candidateSince = nil
            return status
        }
        if candidateStatus != raw {
            candidateStatus = raw
            candidateSince = timestamp
        }
        if let since = candidateSince, timestamp.timeIntervalSince(since) >= dwell {
            status = raw
            candidateStatus = nil
            candidateSince = nil
        }
        return status
    }
}
