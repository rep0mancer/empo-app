import Foundation
import XCTest

@testable import GameProbe

final class RawSaveTransferTests: XCTestCase {
    private var temp: URL!
    private var shared: URL { temp.appendingPathComponent("Data/Test") }
    private var game: URL { temp.appendingPathComponent("Games/Test/Game") }
    private var state: URL { temp.appendingPathComponent("Games/Test/EmpoState") }
    private var backups: URL { temp.appendingPathComponent("Save Import Backups/Test") }
    private var transfer: RawSaveTransfer {
        RawSaveTransfer(game: game, shared: shared, state: state, backups: backups)
    }
    /// Ruby Marshal 4.8 for { :fixture => <binary String> }, as produced by Ruby's Marshal.dump.
    private func bytes(_ text: String) -> Data {
        precondition((1...122).contains(text.utf8.count))
        return Data([4, 8, 0x7b, 6, 0x3a, 12]) + Data("fixture".utf8)
            + Data([0x22, UInt8(text.utf8.count + 5)]) + Data(text.utf8)
    }
    @discardableResult private func write(_ name: String, _ value: String) throws -> URL {
        let url = temp.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes(value).write(to: url)
        return url
    }
    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for url in [shared, game, state] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temp) }

    func testMultipleRootsAreKeptDistinctAndDatabaseFilesAreExcluded() throws {
        try write("Data/Test/Game.rxdata", "shared")
        try write("Games/Test/Game/Save Data/slot2/Game.rxdata", "portable")
        try write("Games/Test/Game/Data/Map001.rxdata", "asset")
        XCTAssertEqual(try transfer.files(in: .shared), ["Game.rxdata"])
        XCTAssertEqual(try transfer.files(in: .portable), ["Save Data/slot2/Game.rxdata"])
        let src = try write("in/Scripts.rxdata", "asset")
        XCTAssertThrowsError(try RawSaveTransfer.stage([src], at: temp.appendingPathComponent("stage")))
    }

    func testImportMakesDurableCopyAndPreservesOriginalSourceAndOtherFiles() throws {
        let old = try write("Data/Test/Game.rxdata", "old")
        let source = try write("in/Game.rxdata", "new")
        let nested = try write("in/slots/Save2.rxdata", "second")
        let unknown = try write("in/notes.txt", "skip")
        let stage = try RawSaveTransfer.stage(
            [source.deletingLastPathComponent()], at: temp.appendingPathComponent("stage"))
        XCTAssertEqual(stage.skipped, 1)
        let plan = try transfer.plan(stage, location: .shared)
        let receipt = try transfer.apply(plan)
        XCTAssertEqual(try Data(contentsOf: old), bytes("new"))
        XCTAssertEqual(
            try Data(contentsOf: shared.appendingPathComponent("slots/Save2.rxdata")),
            try Data(contentsOf: nested))
        XCTAssertEqual(try Data(contentsOf: source), bytes("new"))
        XCTAssertEqual(try Data(contentsOf: unknown), bytes("skip"))
        XCTAssertEqual(
            try Data(contentsOf: XCTUnwrap(receipt).appendingPathComponent("Game.rxdata")), bytes("old"))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: shared.appendingPathComponent("notes.txt").path))
    }

    func testChangedFileCancelsBeforeWritingAndEmptyFirstImportRequiresExplicitLocation() throws {
        let input = try write("src/Game.rxdata", "new")
        let stage = try RawSaveTransfer.stage([input], at: temp.appendingPathComponent("stage"))
        let plan = try transfer.plan(stage, location: .portable)
        let concurrent = try write("Games/Test/Game/Game.rxdata", "later")
        XCTAssertThrowsError(try transfer.apply(plan))
        XCTAssertEqual(try Data(contentsOf: concurrent), bytes("later"))
    }

    func testUnsafeSourceAndDestinationLinksCannotReplaceOutsideFile() throws {
        let input = try write("in/Slot/Game.rxdata", "new")
        let origin = try write("outside/Game.rxdata", "outside")
        try FileManager.default.createSymbolicLink(
            at: shared.appendingPathComponent("Slot"), withDestinationURL: origin.deletingLastPathComponent())
        let stage = try RawSaveTransfer.stage(
            [input.deletingLastPathComponent().deletingLastPathComponent()],
            at: temp.appendingPathComponent("stage"))
        XCTAssertThrowsError(try transfer.plan(stage, location: .shared))
        XCTAssertEqual(try Data(contentsOf: origin), bytes("outside"))
    }
    func testPortableRunaStyleFolderAndDirectFileRoundTrip() throws {
        let existing = try write("Games/Test/Game/Save Data/Game.rxdata", "original")
        let slot = try write("Runa export/Game.rxdata", "runa fixture")
        let extra = try write("Runa export/Backups/Save2.rxdata.bak", "previous slot")
        let staged = try RawSaveTransfer.stage(
            [slot.deletingLastPathComponent()], at: temp.appendingPathComponent("staging"))
        let plan = try transfer.plan(staged, location: .portable, directory: "Save Data")
        let backup = try XCTUnwrap(transfer.apply(plan))
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("Game.rxdata")), bytes("original"))
        XCTAssertEqual(try Data(contentsOf: existing), try Data(contentsOf: slot))
        let exported = try transfer.export(
            location: .portable, directory: "Save Data", file: "Save Data/Game.rxdata",
            into: temp.appendingPathComponent("single"))
        XCTAssertEqual(exported.lastPathComponent, "Game.rxdata")
        XCTAssertEqual(try Data(contentsOf: exported), try Data(contentsOf: slot))
        let zip = try transfer.export(
            location: .portable, directory: "Save Data", into: temp.appendingPathComponent("archive"))
        let reader = try ZipReader(reading: zip)
        let entries = Dictionary(uniqueKeysWithValues: reader.entries.map { ($0.path, $0) })
        XCTAssertEqual(Set(entries.keys), ["Game.rxdata", "Backups/Save2.rxdata.bak"])
        XCTAssertEqual(try reader.data(of: XCTUnwrap(entries["Game.rxdata"])), try Data(contentsOf: slot))
        XCTAssertEqual(
            try reader.data(of: XCTUnwrap(entries["Backups/Save2.rxdata.bak"])), try Data(contentsOf: extra))
    }

    func testFailureAfterFirstReplacementRestoresOriginalAndKeepsBackups() throws {
        let old = try write("Data/Test/Game.rxdata", "old")
        let first = try write("in/Game.rxdata", "new")
        let second = try write("in/Save2.rxdata", "second")
        let stage = try RawSaveTransfer.stage([first, second], at: temp.appendingPathComponent("staging"))
        let plan = try transfer.plan(stage, location: .shared)
        try FileManager.default.removeItem(at: stage.directory.appendingPathComponent("Save2.rxdata"))
        XCTAssertThrowsError(try transfer.apply(plan))
        XCTAssertEqual(try Data(contentsOf: old), bytes("old"))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: shared.appendingPathComponent("Save2.rxdata").path))
        let folder = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil).first)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("Game.rxdata")), bytes("old"))
        XCTAssertNoThrow(try transfer.recover())
    }

    func testInterruptAfterReplacingFirstSlotRecoversAtNextLaunch() throws {
        let old = try write("Data/Test/Game.rxdata", "old")
        let input = try write("in/Game.rxdata", "new")
        let fresh = try write("in/Save2.rxdata", "second")
        let stage = try RawSaveTransfer.stage([input, fresh], at: temp.appendingPathComponent("staging"))
        let plan = try transfer.plan(stage, location: .shared)
        try write("Save Import Backups/Test/\(plan.journal.backup.uuidString)/Game.rxdata", "old")
        try JSONEncoder().encode(plan.journal).write(
            to: state.appendingPathComponent("pending-raw-save-import.json"))
        try bytes("new").write(to: old)
        try transfer.recover()
        XCTAssertEqual(try Data(contentsOf: old), bytes("old"))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: state.appendingPathComponent("pending-raw-save-import.json").path))
    }
    func testCustomPortableSlotNeedsUserMarkAndNeverAllowsGameDatabases() throws {
        let old = try write("Games/Test/Game/Archivio/SlotA.rxdata", "original")
        let imported = try write("input/SlotA.rxdata", "new")
        let stage = try RawSaveTransfer.stage([imported], at: temp.appendingPathComponent("stage"))
        XCTAssertThrowsError(try transfer.plan(stage, location: .portable, directory: "Archivio"))
        let marked = RawSaveTransfer(
            game: game, shared: shared, state: state, backups: backups,
            markedPortableFiles: ["Game/Archivio/SlotA.rxdata", "Game/Data/Actors.rxdata"])
        try write("Games/Test/Game/Data/Actors.rxdata", "game asset")
        XCTAssertEqual(try marked.files(in: .portable), ["Archivio/SlotA.rxdata"])
        _ = try marked.apply(marked.plan(stage, location: .portable, directory: "Archivio"))
        XCTAssertEqual(try Data(contentsOf: old), try Data(contentsOf: imported))
    }

    func testMalformedInputAndUnrecognizedExistingFilesArePreserved() throws {
        let foreign = try write("in/Game.rxdata", "foo")
        try Data([0]).write(to: foreign)
        XCTAssertThrowsError(try RawSaveTransfer.stage([foreign], at: temp.appendingPathComponent("stage")))
        try bytes("valid").write(to: foreign)
        let staged = try RawSaveTransfer.stage([foreign], at: temp.appendingPathComponent("stage"))
        let old = try write("Data/Test/Game.rxdata", "old")
        try Data([0, 1]).write(to: old)
        XCTAssertThrowsError(try transfer.plan(staged, location: .shared))
        XCTAssertEqual(try Data(contentsOf: old), Data([0, 1]))
    }
    func testScriptBundleWithSaveLikeFilenameIsAlwaysProtected() throws {
        let scripts = try write("Games/Test/Game/Save1.rxdata", "game code")
        try Data("[Game]\nScripts=Save1.rxdata\n".utf8).write(to: game.appendingPathComponent("Game.ini"))
        let input = try write("in/Save1.rxdata", "new")
        let stage = try RawSaveTransfer.stage([input], at: temp.appendingPathComponent("staging"))
        XCTAssertTrue(try transfer.files(in: .portable).isEmpty)
        XCTAssertThrowsError(try transfer.plan(stage, location: .portable))
        XCTAssertEqual(try Data(contentsOf: scripts), bytes("game code"))
    }
    func testFirstRunUsesEngineConventionsAndLeavesUnknownLayoutsUnselected() {
        func choice(
            _ kind: RawSaveTransfer.GameLayout, existing: Set<String> = [], manual: String? = nil
        ) -> String? {
            RawSaveTransfer.suggestedDirectory(
                knownSlotDirectories: existing, manualChoice: manual, layout: kind,
                sharedRoot: "Data/Studio/Adventure", portableRoot: "Games/Adventure/Game")
        }
        XCTAssertEqual(choice(.essentials), "Data/Studio/Adventure")
        XCTAssertEqual(choice(.standardXP), "Games/Adventure/Game")
        XCTAssertNil(choice(.unknown))
        XCTAssertEqual(
            choice(.essentials, existing: ["Games/Adventure/Game/Saves"]), "Games/Adventure/Game/Saves")
        XCTAssertNil(choice(.standardXP, existing: ["Data/Studio/Adventure", "Games/Adventure/Game/Saves"]))
        XCTAssertEqual(
            choice(.essentials, manual: "Games/Adventure/Game/Save Data"), "Games/Adventure/Game/Save Data")
    }

    func testProspectiveDirectoriesStayAbsentUntilImportAndHandleBlockedSharedTree() throws {
        try FileManager.default.removeItem(at: shared)
        let fallback = game.deletingLastPathComponent().appendingPathComponent("UserData")
        XCTAssertEqual(RawSaveTransfer.prospectiveSharedDirectory(shared, fallback: fallback), shared)
        XCTAssertEqual(try transfer.portableDirectories(), ["Saves", "Save Data"])
        XCTAssertTrue(try transfer.files(in: .shared).isEmpty)
        for item in [
            shared, fallback, game.appendingPathComponent("Saves"), game.appendingPathComponent("Save Data"),
        ] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: item.path))
        }
        let input = try write("incoming/Save1.rxdata", "slot")
        let staged = try RawSaveTransfer.stage([input], at: temp.appendingPathComponent("stage"))
        let plan = try transfer.plan(staged, location: .portable, directory: "Saves")
        XCTAssertFalse(FileManager.default.fileExists(atPath: game.appendingPathComponent("Saves").path))
        _ = try transfer.apply(plan)
        XCTAssertEqual(
            try Data(contentsOf: game.appendingPathComponent("Saves/Save1.rxdata")),
            try Data(contentsOf: input))
        try Data().write(to: shared)
        XCTAssertEqual(
            RawSaveTransfer.prospectiveSharedDirectory(
                shared.appendingPathComponent("Slot"), fallback: fallback), fallback)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fallback.path))
    }
}
