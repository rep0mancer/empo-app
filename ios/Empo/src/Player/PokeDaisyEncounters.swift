// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Essentials draws a slot from one encounter method at a time. Several slots
/// can yield the same species at different levels.
struct PokeDaisyEncounterMethod: Identifiable {
    struct Entry: Identifiable {
        let species: String
        let chance: Double
        let levels: [ClosedRange<Int>]
        let seen: Bool?
        let caught: Bool?
        var id: String { species }
    }

    let id: String
    let entries: [Entry]

    static func methods(in slots: [EssentialsSnapshot.EncounterSlot]) -> [Self] {
        let valid = slots.filter { $0.weight > 0 && $0.minLevel > 0 && $0.maxLevel >= $0.minLevel }
        return Dictionary(grouping: valid, by: \.method).map { method, slots in
            let total = slots.reduce(0.0) { $0 + Double($1.weight) }
            let entries = Dictionary(grouping: slots, by: \.species).map { species, records in
                let weight = records.reduce(0.0) { $0 + Double($1.weight) }
                let levels = records.map { $0.minLevel...$0.maxLevel }.sorted {
                    $0.lowerBound < $1.lowerBound
                }
                var ranges: [ClosedRange<Int>] = []
                for level in levels {
                    if let last = ranges.last, level.lowerBound - 1 <= last.upperBound {
                        ranges[ranges.count - 1] = last.lowerBound...max(last.upperBound, level.upperBound)
                    } else {
                        ranges.append(level)
                    }
                }
                return Entry(
                    species: species, chance: weight / total, levels: ranges,
                    seen: records.first?.seen, caught: records.first?.caught)
            }.sorted {
                if $0.chance != $1.chance { return $0.chance > $1.chance }
                return $0.species < $1.species
            }
            return Self(id: method, entries: entries)
        }.sorted { $0.id < $1.id }
    }
}
