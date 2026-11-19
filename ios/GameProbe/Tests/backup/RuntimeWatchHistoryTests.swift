// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XCTest

@testable import GameProbe

final class RuntimeWatchHistoryTests: XCTestCase {
    private let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temp)
    }

    func testHistorySurvivesRelaunchAndDamagedCopyIsRetained() throws {
        let file = temp.appendingPathComponent(RuntimeWatchHistory.filename)
        XCTAssertEqual(try RuntimeWatchHistory.merge([], in: temp), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        _ = try RuntimeWatchHistory.merge(["Game/old.bin"], in: temp)
        let both = try RuntimeWatchHistory.merge(["Game/new.bin", "Game/old.bin"], in: temp)
        XCTAssertEqual(both, ["Game/new.bin", "Game/old.bin"])
        XCTAssertEqual(try RuntimeWatchHistory.merge([], in: temp), both)
        let damaged = Data("partial".utf8)
        try damaged.write(to: file)
        XCTAssertThrowsError(try RuntimeWatchHistory.merge(["Game/later"], in: temp))
        XCTAssertEqual(try Data(contentsOf: file), damaged)
    }

    func testUnrecognizedCacheIsNeverRebuiltByPatchInspection() throws {
        let url = temp.appendingPathComponent("state.sqlite")
        let db = try SQLiteDatabase(url: url)
        try db.execute("CREATE TABLE future_cache(value INTEGER)")
        try db.setUserVersion(99)
        db.close()
        XCTAssertThrowsError(try RuntimeWatchHistory.cachedJoins(in: url, folderName: "Island"))
        let check = try SQLiteDatabase(url: url, readOnly: true)
        XCTAssertEqual(try check.userVersion, 99)
        XCTAssertEqual(try check.tableNames(), ["future_cache"])
        XCTAssertThrowsError(try check.execute("DELETE FROM future_cache"))
    }

    func testAllCachedTargetsForThisGameContributeOnlyContainerWatchEntries() throws {
        let url = temp.appendingPathComponent("state.sqlite")
        XCTAssertEqual(try RuntimeWatchHistory.cachedJoins(in: url, folderName: "Island"), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let store = try BackupStateStore(url: url)
        defer { store.close() }
        func entry(_ path: String, _ root: EntryRoot, _ source: DetectionSource) -> SnapshotManifest.Entry {
            .init(
                root: root, path: path, size: 1, modifiedAt: Date(), hash: String(repeating: "a", count: 64),
                compression: .stored, detectionSource: source)
        }
        func add(_ game: String, _ target: String, _ entries: [SnapshotManifest.Entry]) throws {
            try store.recordUploadedManifest(
                .init(mode: .slim, containerFolderName: game, entries: entries),
                snapshotId: "latest", targetId: target, uploadedAt: Date())
        }
        try add("Island", "first", [
            entry("Game/Data/slot1.bin", .container, .runtimeWatch),
            entry("Game/setting.ini", .container, .manualMark),
            entry("slot.bin", .sharedData, .runtimeWatch),
        ])
        try add("Island", "second", [entry("Game/Data/slot2.bin", .container, .runtimeWatch)])
        try add("Other", "first", [entry("Game/other.bin", .container, .runtimeWatch)])
        XCTAssertEqual(
            try RuntimeWatchHistory.cachedJoins(in: url, folderName: "Island"),
            ["Game/Data/slot1.bin", "Game/Data/slot2.bin"])
    }
}
