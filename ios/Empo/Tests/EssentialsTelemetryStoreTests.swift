// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import XCTest

@testable import Empo

@MainActor
final class EssentialsTelemetryStoreTests: XCTestCase {
    private let live = #"""
        {"schemaVersion":1,"map":{"id":53,"name":"Pokémon Academy"},"party":[
          {"species":"EEVEE","nickname":"Étoile","level":7,"hp":17,"maxHP":23,
           "status":null,"item":"ORANBERRY","moves":[{"id":"TACKLE","pp":32,"maxPP":35}],
           "types":["NORMAL"]}],"encounters":[
          {"method":"Land","weight":20,"species":"CUSTOM_SPECIES","minLevel":3,"maxLevel":6,
           "seen":false,"caught":null}],"battle":{"allies":[
          {"index":0,"species":"EEVEE","types":["NORMAL"],"hpPercent":74,"stages":{}}],
          "opponents":[{"index":1,"species":"CUSTOM_SPECIES","types":["WATER"],
           "hpPercent":25,"stages":{"ATTACK":-1,"CUSTOM_STAT":2}}]}}
        """#

    func testDecodesGameIDsUnicodeAndOptionalKnowledge() throws {
        let store = EssentialsTelemetryStore()
        store.receive(Data(live.utf8))
        let snap = try XCTUnwrap(store.snapshot)
        XCTAssertEqual(snap.map?.name, "Pokémon Academy")
        XCTAssertEqual(snap.party.first?.nickname, "Étoile")
        XCTAssertEqual(snap.party.first?.moves.first?.maxPP, 35)
        XCTAssertEqual(snap.party.first?.item, "ORANBERRY")
        XCTAssertNil(snap.party.first?.status)
        let slot = try XCTUnwrap(snap.encounters?.first)
        XCTAssertEqual(slot.weight, 20)
        XCTAssertEqual(slot.seen, false)
        XCTAssertNil(slot.caught)
        XCTAssertEqual(snap.battle?.allies.first?.hpPercent, 74)
        XCTAssertEqual(snap.battle?.opponents.first?.stages["CUSTOM_STAT"], 2)
    }

    func testOptionalGameLocalizedMoveAndItemNames() throws {
        let store = EssentialsTelemetryStore()
        store.receive(Data(live.utf8))
        let original = try XCTUnwrap(store.snapshot?.party.first)
        XCTAssertNil(original.itemName)
        XCTAssertNil(original.moves.first?.name)
        let named =
            live
            .replacingOccurrences(
                of: #""item":"ORANBERRY""#, with: #""item":"ORANBERRY","itemName":"Baie Oran""#
            )
            .replacingOccurrences(of: #""id":"TACKLE""#, with: #""id":"TACKLE","name":"Charge Éclair""#)
        store.receive(Data(named.utf8))
        let member = try XCTUnwrap(store.snapshot?.party.first)
        XCTAssertEqual(member.itemName, "Baie Oran")
        XCTAssertEqual(member.moves.first?.name, "Charge Éclair")
        XCTAssertEqual(member.item, original.item)
        XCTAssertEqual(member.moves.first?.id, original.moves.first?.id)
    }

    func testDecodesOptionalDirectionalTypeChart() throws {
        let store = EssentialsTelemetryStore()
        store.receive(Data(live.utf8))
        XCTAssertNil(store.snapshot?.battle?.opponents.first?.incomingEffectiveness)
        let enriched = live.replacingOccurrences(
            of: #""hpPercent":25"#,
            with: #""hpPercent":25,"incomingEffectiveness":{"NORMAL":0,"CUSTOM_TYPE":0.25}"#)
        store.receive(Data(enriched.utf8))
        let chart = try XCTUnwrap(store.snapshot?.battle?.opponents.first?.incomingEffectiveness)
        XCTAssertEqual(chart["NORMAL"], 0)
        XCTAssertEqual(chart["CUSTOM_TYPE"], 0.25)
        XCTAssertNil(chart["UNKNOWN"])
        XCTAssertNil(store.snapshot?.battle?.allies.first?.incomingEffectiveness)
    }

    func testUpdatesReplaceOldSectionsAndResetClearsTheSession() throws {
        let store = EssentialsTelemetryStore()
        store.receive(Data(live.utf8))
        store.receive(
            Data(#"{"schemaVersion":1,"map":{"id":2,"name":"Cave"},"party":[],"encounters":[]}"#.utf8))
        let snap = try XCTUnwrap(store.snapshot)
        XCTAssertNil(snap.battle)
        XCTAssertTrue(snap.party.isEmpty)
        XCTAssertEqual(snap.encounters, [])
        store.reset()
        XCTAssertNil(store.snapshot)
    }

    func testUnsupportedInvalidOversizedAndTitleScreenClearOldState() {
        let store = EssentialsTelemetryStore()
        for invalid in [
            Data(#"{"schemaVersion":2,"party":[],"encounters":[]}"#.utf8), Data("{}".utf8),
            Data(repeating: 32, count: 65537), Data(#"{"schemaVersion":1,"party":[]}"#.utf8),
        ] {
            store.receive(Data(live.utf8))
            XCTAssertNotNil(store.snapshot)
            store.receive(invalid)
            XCTAssertNil(store.snapshot)
        }
    }
}
