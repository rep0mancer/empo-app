// SPDX-License-Identifier: GPL-3.0-only

import XCTest

@testable import Empo

final class PokeDaisyEncountersTests: XCTestCase {
    private typealias Slot = EssentialsSnapshot.EncounterSlot

    private func slot(_ method: String, _ species: String, _ weight: Int, levels: ClosedRange<Int>) -> Slot {
        Slot(
            method: method, weight: weight, species: species,
            minLevel: levels.lowerBound, maxLevel: levels.upperBound, seen: nil, caught: nil)
    }

    func testSpeciesRatesUseAllSlotsWithinTheirOwnMethod() throws {
        let groups = PokeDaisyEncounterMethod.methods(in: [
            slot("Field", "A", 3, levels: 4...6), slot("Field", "B", 8, levels: 3...4),
            slot("Field", "A", 1, levels: 6...8), slot("Surf", "A", 1, levels: 1...1),
        ])
        XCTAssertEqual(groups.map(\.id), ["Field", "Surf"])
        let field = try XCTUnwrap(groups.first)
        XCTAssertEqual(field.entries.map(\.species), ["B", "A"])
        XCTAssertEqual(field.entries[1].chance, 1.0 / 3.0, accuracy: 1e-10)
        XCTAssertEqual(field.entries[1].levels, [4...8])
        XCTAssertEqual(groups.last?.entries.first?.chance, 1)
        XCTAssertNil(field.entries[0].seen)
        XCTAssertNil(field.entries[0].caught)
    }

    func testGapsInPossibleLevelsRemainVisible() throws {
        let entry = try XCTUnwrap(
            PokeDaisyEncounterMethod.methods(in: [
                slot("Grove", "FOX", 3, levels: 4...5), slot("Grove", "FOX", 5, levels: 7...10),
                slot("Grove", "FOX", 1, levels: 11...12),
            ]).first?.entries.first)
        XCTAssertEqual(entry.levels, [4...5, 7...12])
        XCTAssertEqual(entry.chance, 1)
    }
}
