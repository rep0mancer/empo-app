// SPDX-License-Identifier: GPL-3.0-only
#if os(iOS)
import Foundation
import GameProbe

struct GamePatchReview: Sendable {
    fileprivate let plan: GamePatch.Review
    fileprivate let gameIdentity: UUID
    fileprivate let scratch: URL
    var added: [String] { plan.added }
    var replaced: [String] { plan.replaced }
    var preserved: [String] { plan.preserved }
}

@MainActor
enum GamePatchInstaller {
    private static func available(_ game: GameEntry) throws -> GameContainer {
        guard game.status == .ready, let container = game.container,
            GameCores.core(forGameAt: container.gameURL) is MkxpCore,
            !GameLibrary.shared.inFlightImports.withLock({ $0.contains(game.id) }),
            !GameLibrary.shared.deletionsInFlight.withLock({ $0.contains(game.id) }),
            !BackupDeviceConditions.isSessionLive, !GameRawSaves.isTransferring,
            !RestoreCoordinator.shared.isRestoring
        else {
            throw CocoaError(
                .fileWriteUnknown,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        String(
                            localized: "Close the running game and wait for other file operations to finish.")
                ])
        }
        return container
    }

    static func prepare(file: URL, isFolder: Bool, game: GameEntry) async throws -> GamePatchReview {
        let container = try available(game)
        let watched = try await GameSaveWatch.shared.patchPaths(for: container)
        let marks = try GameBackupIntent.load(from: container.empoStateURL).manualMarks + watched
        let scratch = try ImportTemporaryDirectory.makeScopedDirectory(kind: .patch)
        do {
            let plan = try await read(
                file, isFolder: isFolder, game: container.gameURL, marks: marks, scratch: scratch)
            return GamePatchReview(plan: plan, gameIdentity: game.viewIdentity, scratch: scratch)
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            throw error
        }
    }

    nonisolated private static func read(
        _ file: URL, isFolder: Bool, game: URL, marks: [String], scratch: URL
    ) async throws -> GamePatch.Review {
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        let intent = NSFileAccessIntent.readingIntent(with: file, options: .withoutChanges)
        return try await withCheckedThrowingContinuation { continuation in
            NSFileCoordinator().coordinate(with: [intent], queue: OperationQueue()) { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(
                    with: Result {
                        var source = intent.url
                        if !isFolder, ArchiveExtractor.Format(extension: file.pathExtension) != nil {
                            source = scratch.appendingPathComponent("Extracted")
                            try ArchiveExtractor.extract(archive: intent.url, to: source)
                        }
                        return try GamePatch.prepare(
                            source: source, game: game,
                            overlay: scratch.appendingPathComponent("Overlay"), marks: marks)
                    })
            }
        }
    }

    static func discard(_ review: GamePatchReview) {
        let scratch = review.scratch
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: scratch) }
    }

    static func apply(_ review: GamePatchReview, game: GameEntry) async throws {
        let container = try available(game)
        guard review.gameIdentity == game.viewIdentity else { throw CocoaError(.fileNoSuchFile) }
        let outcome = await BackupScheduler.shared.withRunsHeld {
            do {
                let watched = try await GameSaveWatch.shared.patchPaths(for: container)
                _ = try available(game)
                let core = MkxpCore()
                try GameRawSaves.recover(container, core: core)
                let marks = try GameBackupIntent.load(from: container.empoStateURL).manualMarks + watched
                let current = core.sharedDataFolder(for: container)
                GameRawSaves.isTransferring = true
                GameLibrary.shared.inFlightImports.withLock { _ = $0.insert(game.id) }
                defer {
                    GameRawSaves.isTransferring = false
                    GameLibrary.shared.inFlightImports.withLock { _ = $0.remove(game.id) }
                }
                let backup = DataDirectory.documentsRootURL.appendingPathComponent("Patch Backups")
                    .appendingPathComponent(container.folderName).appendingPathComponent(UUID().uuidString)
                try await Task.detached(priority: .userInitiated) {
                    try GamePatch.apply(review.plan, game: container.gameURL, marks: marks, backup: backup) {
                        staged in
                        guard GameCores.core(forGameAt: staged) is MkxpCore else {
                            throw CocoaError(
                                .fileReadCorruptFile,
                                userInfo: [
                                    NSLocalizedDescriptionKey:
                                        String(
                                            localized:
                                                "The updated folder is no longer a recognized RPG Maker game."
                                        )
                                ])
                        }
                        try MkxpCore().validateGameRoot(staged) { relative in
                            guard !relative.hasPrefix("/"),
                                !relative.split(separator: "/").contains("..")
                            else { throw CocoaError(.fileReadInvalidFileName) }
                        }
                        if let current, current != MkxpCore.declaredSaveFolder(container, tree: staged) {
                            _ = container.ensureEmpoStateDirectory()
                            try JSONEncoder().encode(current).write(
                                to: MkxpCore.patchSaveIdentityURL(container), options: .atomic)
                        }
                    }
                    _ = MkxpProfile.load(for: container, rescan: true)
                }.value
                GameLibrary.shared.refreshGameEntry(id: game.id)
                BackupScheduler.shared.markDirty(container: container)
                return Result<Void, Error>.success(())
            } catch { return .failure(error) }
        }
        try outcome.get()
    }
}
#endif
