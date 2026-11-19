// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Durable protection for the nonstandard save filenames discovered during play.
public enum RuntimeWatchHistory {
    static let filename = "runtime-watch-paths.json"

    /// The session watcher serializes all calls on the main actor. A corrupt
    /// history stays on disk and the patch preview fails until it can be read.
    public static func merge(_ additions: Set<String>, in stateDirectory: URL) throws -> [String] {
        let file = stateDirectory.appendingPathComponent(filename)
        let previous: Set<String>
        do {
            previous = try JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: file))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            previous = []
        }
        let combined = previous.union(additions)
        let sorted = combined.sorted()
        if previous != combined {
            try JSONEncoder().encode(sorted).write(to: file, options: .atomic)
        }
        return sorted
    }

    /// Open the existing cache without migrating or rebuilding it, even if
    /// an older build wrote it. Read each target's latest manifest locally.
    public static func cachedJoins(in url: URL, folderName: String) throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let db = try SQLiteDatabase(url: url, readOnly: true)
        let key: SQLiteValue = .text(BackupKeys.gameKey(containerFolderName: folderName))
        let targets = try db.query("SELECT targetId FROM uploaded_manifest WHERE gameKey = ?", [key])
        var paths = Set<String>()
        for target in targets {
            guard let targetID = target.first else { continue }
            let rows = try db.query(
                "SELECT manifest FROM uploaded_manifest WHERE targetId = ? AND gameKey = ?", [targetID, key])
            guard let data = rows.first?.first?.data else { continue }
            let manifest = try SnapshotManifest.decode(json: data)
            for entry in manifest.entries where entry.root == .container && entry.detectionSource == .runtimeWatch {
                paths.insert(entry.path)
            }
        }
        return paths
    }
}
