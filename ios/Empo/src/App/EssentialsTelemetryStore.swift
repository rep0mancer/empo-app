// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Observation

/// An immutable snapshot from the current Essentials VM. Symbolic game IDs are
/// strings so a fangame can introduce its own species, moves, types and stats.
struct EssentialsSnapshot: Decodable, Equatable, Sendable {
    struct Map: Decodable, Equatable, Sendable {
        let id: Int
        let name: String
    }

    struct Move: Decodable, Equatable, Sendable {
        let id: String
        let pp: Int
        let maxPP: Int
    }

    struct PartyMember: Decodable, Equatable, Sendable {
        let species: String
        let nickname: String
        let level: Int
        let hp: Int
        let maxHP: Int
        let status: String?
        let item: String?
        let types: [String]
        let moves: [Move]
    }

    struct EncounterSlot: Decodable, Equatable, Sendable {
        let method: String
        /// Relative to other slots for the same encounter method.
        let weight: Int
        let species: String
        let minLevel: Int
        let maxLevel: Int
        let seen: Bool?
        let caught: Bool?
    }

    struct Battler: Decodable, Equatable, Sendable {
        let index: Int
        let species: String
        let types: [String]
        let hpPercent: Int
        let stages: [String: Int]
        /// Opposing attack type to this battler's base type-chart multiplier.
        /// A missing key means unavailable. A zero means immune.
        let incomingEffectiveness: [String: Double]?
    }

    struct Battle: Decodable, Equatable, Sendable {
        let allies: [Battler]
        let opponents: [Battler]
    }

    let schemaVersion: Int
    let map: Map?
    let party: [PartyMember]
    /// Nil means the game didn't supply encounter data. An empty array is a known empty table.
    let encounters: [EncounterSlot]?
    let battle: Battle?
}

/// Read by the native companion. The transport rejects messages from previous
/// sessions before they reach this store. No game data is written to disk.
@MainActor @Observable
final class EssentialsTelemetryStore {
    static let shared = EssentialsTelemetryStore()
    private(set) var snapshot: EssentialsSnapshot?
    private let decoder = JSONDecoder()

    func receive(_ data: Data) {
        guard data.count <= 64 * 1024,
            let next = try? decoder.decode(EssentialsSnapshot.self, from: data),
            next.schemaVersion == 1,
            next.map != nil || !next.party.isEmpty || next.encounters != nil || next.battle != nil
        else {
            reset()
            return
        }
        if snapshot != next { snapshot = next }
    }

    func reset() {
        if snapshot != nil { snapshot = nil }
    }
}
