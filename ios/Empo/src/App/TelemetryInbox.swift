// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Synchronization

/// The VM and XPC queues hand snapshots to the main actor. Keep only the most
/// recent pending value when the main actor is busy.
final class TelemetryInbox: Sendable {
    private struct State {
        var generation: Int?
        var pending: Data?
    }

    private let state = Mutex(State())

    func reset(to generation: Int? = nil) {
        state.withLock { $0 = State(generation: generation) }
    }

    /// Returns true for the caller that should schedule delivery.
    func offer(_ bytes: UnsafeRawPointer?, count: Int, generation: Int) -> Bool {
        guard let bytes, count > 0, count <= Int(GAMECORE_MAX_TELEMETRY_BYTES) else { return false }
        return state.withLock { state in
            guard state.generation == generation else { return false }
            let schedule = state.pending == nil
            state.pending = Data(bytes: bytes, count: count)
            return schedule
        }
    }

    func take(generation: Int) -> Data? {
        state.withLock { state in
            guard state.generation == generation else { return nil }
            defer { state.pending = nil }
            return state.pending
        }
    }
}
