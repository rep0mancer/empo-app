// SPDX-License-Identifier: GPL-3.0-only

/// Several native surfaces can hold one engine pause. Serialize both bridge
/// commands with their acknowledgements so a late callback cannot undo a newer intent.
public struct SessionPauseHolds {
    public enum Reason: Hashable { case overlay, background, library, systemSheet }
    public enum Command { case none, pause, resume }
    private enum State { case starting, running, requestingPause, parked, requestingResume }

    private var reasons: Set<Reason> = []
    private var state = State.starting

    public init() {}
    public var isRunning: Bool { state == .running }
    public var isParked: Bool { state == .parked }
    public var countsPlayTime: Bool { reasons.isEmpty && (state == .starting || state == .running) }
    public func contains(_ reason: Reason) -> Bool { reasons.contains(reason) }

    public mutating func set(_ reason: Reason, active: Bool) -> Command {
        if active {
            reasons.insert(reason)
        } else {
            reasons.remove(reason)
        }
        return reconcile()
    }

    public mutating func didStart() -> Command {
        guard state == .starting else { return .none }
        state = .running
        return reconcile()
    }

    public mutating func didPause() -> Command {
        guard state == .requestingPause else { return .none }
        state = .parked
        return reconcile()
    }

    public mutating func didResume() -> Command {
        guard state == .requestingResume else { return .none }
        state = .running
        return reconcile()
    }

    private mutating func reconcile() -> Command {
        if state == .running && !reasons.isEmpty {
            state = .requestingPause
            return .pause
        }
        if state == .parked && reasons.isEmpty {
            state = .requestingResume
            return .resume
        }
        return .none
    }
}