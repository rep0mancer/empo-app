// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XCTest

@testable import GameProbe

final class GamePatchTests: XCTestCase {
    private let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private var game: URL { temp.appendingPathComponent("Installed") }
    private var source: URL { temp.appendingPathComponent("Downloaded") }
    private var overlay: URL { temp.appendingPathComponent("Overlay") }
    private let fm = FileManager.default

    private func write(_ text: String, _ base: URL, _ path: String) throws {
        let file = base.appendingPathComponent(path)
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file, options: .atomic)
    }
    private func read(_ path: String) throws -> String {
        try String(contentsOf: game.appendingPathComponent(path), encoding: .utf8)
    }
    private func plan(_ url: URL? = nil, marks: [String] = []) throws -> GamePatch.Review {
        try GamePatch.prepare(source: url ?? source, game: game, overlay: overlay, marks: marks)
    }
    override func setUpWithError() throws {
        try write("original", game, "Data/Scripts.rxdata")
        try write("progress", game, "Save01.rxdata")
    }
    override func tearDownWithError() throws { try fm.removeItem(at: temp) }

    func testWrappedUpdateWithSavesMarkedFilesAndWindowsCasing() throws {
        try write("progress2", game, "Saves/Slot.bin")
        try write("profile", game, "Data/Custom.dat")
        try write("fixed", source, "release/data/scripts.rxdata")
        try write("translation", source, "release/Data/Messages.dat")
        try write("incoming", source, "release/Save01.rxdata")
        try write("incoming2", source, "release/Saves/Slot.bin")
        try write("incoming3", source, "release/Data/Custom.dat")
        let marks = ["Game/Data/Custom.dat"]
        let review = try plan(marks: marks)
        XCTAssertEqual(review.replaced, ["Data/Scripts.rxdata"])
        XCTAssertEqual(review.added, ["Data/Messages.dat"])
        XCTAssertEqual(Set(review.preserved), ["Save01.rxdata", "Saves/Slot.bin", "Data/Custom.dat"])
        XCTAssertEqual(try read("Data/Scripts.rxdata"), "original")
        try GamePatch.apply(review, game: game, marks: marks)
        XCTAssertEqual(try read("Data/Scripts.rxdata"), "fixed")
        XCTAssertEqual(try read("Data/Messages.dat"), "translation")
        XCTAssertEqual(try read("Save01.rxdata"), "progress")
        XCTAssertEqual(try read("Saves/Slot.bin"), "progress2")
        XCTAssertEqual(try read("Data/Custom.dat"), "profile")
    }

    func testSelectedAssetFolderAndLooseFile() throws {
        try write("fixed", source, "Data/Scripts.rxdata")
        let folder = try plan(source.appendingPathComponent("Data"))
        XCTAssertEqual(folder.replaced, ["Data/Scripts.rxdata"])
        try fm.removeItem(at: overlay)
        let loose = try plan(source.appendingPathComponent("Data/Scripts.rxdata"))
        XCTAssertEqual(loose.replaced, ["Data/Scripts.rxdata"])
        try GamePatch.apply(loose, game: game, marks: [])
        XCTAssertEqual(try read("Data/Scripts.rxdata"), "fixed")
        try write("other", game, "Plugins/Scripts.rxdata")
        XCTAssertThrowsError(try plan(source.appendingPathComponent("Data/Scripts.rxdata")))
    }

    func testChangedOrNewlyProtectedTargetRequiresNewPreview() throws {
        try write("fixed", source, "Data/Scripts.rxdata")
        let review = try plan()
        XCTAssertThrowsError(try GamePatch.apply(review, game: game, marks: ["Game/Data/Scripts.rxdata"]))
        try write("external edit", game, "Data/Scripts.rxdata")
        XCTAssertThrowsError(try GamePatch.apply(review, game: game, marks: []))
        XCTAssertEqual(try read("Data/Scripts.rxdata"), "external edit")
    }

    func testInvalidResultKeepsOriginalAndFileFolderConflictIsRejected() throws {
        try write("fixed", source, "Data/Scripts.rxdata")
        let review = try plan()
        XCTAssertThrowsError(
            try GamePatch.apply(review, game: game, marks: []) { _ in throw CocoaError(.fileReadCorruptFile) }
        )
        XCTAssertEqual(try read("Data/Scripts.rxdata"), "original")
        try fm.removeItem(at: source)
        try write("oops", source, "Data")
        XCTAssertThrowsError(try plan())
        XCTAssertEqual(try read("Save01.rxdata"), "progress")
    }

    func testWrapperWithReadmeKeepsProgressAndOriginalReplacement() throws {
        try write("manual", game, "README.txt")
        try write("publisher notes", source, "README.txt")
        try write("fixed", source, "release/Data/Scripts.rxdata")
        try write("game progress", game, "Data/Saves/Game.rxdata")
        try write("demo progress", source, "release/Data/Saves/Game.rxdata")
        let review = try plan()
        XCTAssertEqual(review.replaced, ["Data/Scripts.rxdata"])
        XCTAssertEqual(review.preserved, ["Data/Saves/Game.rxdata"])
        let backup = temp.appendingPathComponent("Backups/one")
        try GamePatch.apply(review, game: game, marks: [], backup: backup)
        XCTAssertEqual(
            try String(contentsOf: backup.appendingPathComponent("Data/Scripts.rxdata"), encoding: .utf8),
            "original")
        XCTAssertEqual(try read("README.txt"), "manual")
        XCTAssertEqual(try read("Data/Saves/Game.rxdata"), "game progress")
    }

    func testReinstalledGameRejectsAdditionOnlyPreview() throws {
        try write("French", source, "Data/Text-fr.dat")
        let review = try plan()
        XCTAssertEqual(review.added, ["Data/Text-fr.dat"])
        try fm.moveItem(at: game, to: temp.appendingPathComponent("Previous"))
        try write("new install", game, "Data/Scripts.rxdata")
        XCTAssertThrowsError(try GamePatch.apply(review, game: game, marks: []))
        XCTAssertFalse(fm.fileExists(atPath: game.appendingPathComponent("Data/Text-fr.dat").path))
    }

    func testLinksRejectedWithoutChangingTarget() throws {
        try write("external", temp, "outside")
        try fm.createDirectory(at: source.appendingPathComponent("Data"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            at: source.appendingPathComponent("Data/file"),
            withDestinationURL: temp.appendingPathComponent("outside"))
        XCTAssertThrowsError(try plan())
        XCTAssertEqual(try read("Data/Scripts.rxdata"), "original")
    }
}
