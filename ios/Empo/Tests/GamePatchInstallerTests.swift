// SPDX-License-Identifier: GPL-3.0-only
import GameProbe
import XCTest

@testable import Empo

@MainActor
final class GamePatchInstallerTests: XCTestCase {
    private let files = FileManager.default
    private let input = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private let container = GameContainer(folderName: "PatchInstallerTests-\(UUID().uuidString)")
    private var game: GameEntry!
    private var shared: URL!

    override func setUp() async throws {
        try await super.setUp()
        let name = container.folderName
        game = GameEntry(id: name, container: container, title: name, artworkPath: nil)
        try write(ini(title: name), to: container.gameIniURL)
        // A Ruby Marshal dump of an empty script array.
        try write(
            Data([0x04, 0x08, 0x5b, 0x00]),
            to: container.gameURL.appendingPathComponent("Data/Scripts.rxdata"))
        try write("installed", at: "Data/Map001.rxdata", in: container.gameURL)
        try files.createDirectory(at: input, withIntermediateDirectories: true)
        let resolved = try XCTUnwrap(DataDirectory.resolve(for: container, core: MkxpCore()))
        // Only create or remove the data directory named for this test run.
        guard resolved.lastPathComponent == name, !files.fileExists(atPath: resolved.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        shared = resolved
        try write(Data([0x04, 0x08, 0x7b, 0x00]), to: shared.appendingPathComponent("Game.rxdata"))
    }

    override func tearDown() async throws {
        if files.fileExists(atPath: input.path) { try files.removeItem(at: input) }
        if files.fileExists(atPath: container.url.path) { try files.removeItem(at: container.url) }
        if let shared, files.fileExists(atPath: shared.path) { try files.removeItem(at: shared) }
        try await super.tearDown()
    }

    func testZipUpdatesINIWithoutRedirectingSavesOrReplacingPlayerSettings() async throws {
        let portable = container.gameURL.appendingPathComponent("Save01.rxdata")
        let marked = container.gameURL.appendingPathComponent("Data/Player.dat")
        let save = Data([0x04, 0x08, 0x7b, 0x00])
        try write(save, to: portable)
        try write("player", at: "Data/Player.dat", in: container.gameURL)
        try GameBackupIntent(manualMarks: ["Game/Data/Player.dat"]).save(to: container.empoStateURL)
        var settings = GameSettings()
        settings.speedMultiplier = 2
        settings.save(to: container.empoStateURL)
        let savedSettings = try Data(contentsOf: container.gameSettingsURL)
        let newTitle = container.id + "-patched"
        let picked = input.appendingPathComponent("update.zip")
        let zip = try ZipWriter(creating: picked)
        try zip.add(data: ini(title: newTitle), at: "release/Game.ini")
        try zip.add(data: Data("update".utf8), at: "release/Data/Map001.rxdata")
        try zip.add(data: Data("new".utf8), at: "release/Graphics/Hero.png")
        try zip.add(data: Data("foreign save".utf8), at: "release/Save01.rxdata")
        try zip.add(data: Data("foreign profile".utf8), at: "release/Data/Player.dat")
        try zip.finish()

        let review = try await GamePatchInstaller.prepare(file: picked, isFolder: false, game: game)
        defer { GamePatchInstaller.discard(review) }
        XCTAssertEqual(review.added, ["Graphics/Hero.png"])
        XCTAssertEqual(Set(review.replaced), ["Game.ini", "Data/Map001.rxdata"])
        XCTAssertEqual(Set(review.preserved), ["Data/Player.dat", "Save01.rxdata"])
        XCTAssertEqual(GameINI.gameTitle(at: container.gameURL), container.id)
        try await GamePatchInstaller.apply(review, game: game)

        XCTAssertEqual(GameINI.gameTitle(at: container.gameURL), newTitle)
        XCTAssertEqual(try installed("Data/Map001.rxdata"), "update")
        XCTAssertEqual(try installed("Graphics/Hero.png"), "new")
        let active = try XCTUnwrap(DataDirectory.resolveAndPrepare(for: container, core: MkxpCore()))
        XCTAssertEqual(active.standardizedFileURL, shared.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: active.appendingPathComponent("Game.rxdata")), save)
        XCTAssertEqual(try Data(contentsOf: portable), save)
        XCTAssertEqual(try Data(contentsOf: marked), Data("player".utf8))
        XCTAssertEqual(try Data(contentsOf: container.gameSettingsURL), savedSettings)
        XCTAssertEqual(GameSettings.load(from: container.empoStateURL).speedMultiplier, 2)
        XCTAssertTrue(files.fileExists(atPath: picked.path))
    }

    func testDiscardedFolderLeavesGameIntactAndApplyUsesReviewedBytes() async throws {
        let selected = input.appendingPathComponent("Data")
        try write("reviewed map", at: "Map001.rxdata", in: selected)
        let canceled = try await GamePatchInstaller.prepare(file: selected, isFolder: true, game: game)
        XCTAssertEqual(canceled.replaced, ["Data/Map001.rxdata"])
        GamePatchInstaller.discard(canceled)
        XCTAssertEqual(try installed("Data/Map001.rxdata"), "installed")

        let review = try await GamePatchInstaller.prepare(file: selected, isFolder: true, game: game)
        defer { GamePatchInstaller.discard(review) }
        try write("later source edit", at: "Map001.rxdata", in: selected)
        try await GamePatchInstaller.apply(review, game: game)
        XCTAssertEqual(try installed("Data/Map001.rxdata"), "reviewed map")
        XCTAssertEqual(
            try String(contentsOf: selected.appendingPathComponent("Map001.rxdata"), encoding: .utf8),
            "later source edit")
    }

    func testLooseFileChecksSaveTransferAgainAtApply() async throws {
        let selected = input.appendingPathComponent("MAP001.rxdata")
        try write(Data("loose update".utf8), to: selected)
        let review = try await GamePatchInstaller.prepare(file: selected, isFolder: false, game: game)
        defer { GamePatchInstaller.discard(review) }
        XCTAssertEqual(review.replaced, ["Data/Map001.rxdata"])
        let priorTransfer = GameRawSaves.isTransferring
        GameRawSaves.isTransferring = true
        defer { GameRawSaves.isTransferring = priorTransfer }
        do {
            try await GamePatchInstaller.apply(review, game: game)
            XCTFail("A pending save transfer must block patch installation")
        } catch {
            XCTAssertEqual(try installed("Data/Map001.rxdata"), "installed")
        }
        GameRawSaves.isTransferring = priorTransfer
        try await GamePatchInstaller.apply(review, game: game)
        XCTAssertEqual(try installed("Data/Map001.rxdata"), "loose update")
    }

    private func ini(title: String) -> Data {
        Data("[Game]\nLibrary=RGSS102E.dll\nScripts=Data/Scripts.rxdata\nTitle=\(title)\n".utf8)
    }

    private func installed(_ path: String) throws -> String {
        try String(contentsOf: container.gameURL.appendingPathComponent(path), encoding: .utf8)
    }

    private func write(_ text: String, at path: String, in root: URL) throws {
        try write(Data(text.utf8), to: root.appendingPathComponent(path))
    }

    private func write(_ data: Data, to url: URL) throws {
        try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
