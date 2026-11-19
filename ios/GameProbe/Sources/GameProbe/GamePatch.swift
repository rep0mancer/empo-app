// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// A patch owns a private copy of its inputs from Files. Only reviewed paths
/// can be merged, and the installed tree changes in a single directory swap.
public enum GamePatch {
    public struct Failure: LocalizedError {
        public let errorDescription: String?
        init(_ reason: String) { errorDescription = reason }
    }

    fileprivate struct Stamp: Equatable, Sendable {
        let size: UInt64
        let modified: Date?
        let inode: UInt64
    }

    public struct Review: Sendable {
        public let added: [String]
        public let replaced: [String]
        public let preserved: [String]
        fileprivate let stamps: [String: Stamp]
        fileprivate let overlay: URL
        fileprivate let game: URL
        fileprivate let gameInode: UInt64
    }

    private static let assetFolders: Set<String> = [
        "data", "audio", "graphics", "pbs", "plugins", "fonts", "system", "movies",
        "translations", "language", "languages", "locales",
    ]
    private static let reserved: Set<String> = [
        "empostate", "userdata", "metadata", "logs", "rescued saves", "save import backups",
    ]

    private static func kind(_ url: URL) throws -> FileAttributeType {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let type = attrs[.type] as? FileAttributeType,
            type == .typeRegular || type == .typeDirectory
        else { throw Failure("Cannot patch a link or special file at \(url.lastPathComponent).") }
        return type
    }

    private static func children(_ url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "__MACOSX" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func checkTree(_ root: URL) throws {
        guard try kind(root) == .typeDirectory else { throw Failure("A game folder is required.") }
        var interruption: Error?
        let entries = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil,
            errorHandler: { _, error in
                interruption = error
                return false
            })
        guard let entries else { throw Failure("Could not read the game folder.") }
        for case let url as URL in entries { _ = try kind(url) }
        if let interruption { throw interruption }
    }

    private static func root(in folder: URL, game: URL) throws -> (URL, String) {
        let installed = try children(game)
        let installedNames = Set(installed.map { $0.lastPathComponent.lowercased() })
        let installedFolders = Set(
            try installed.filter { try kind($0) == .typeDirectory }.map { $0.lastPathComponent.lowercased() })
        let folderAnchors = assetFolders.union(installedFolders)
        var current = folder
        while true {
            let name = current.lastPathComponent
            if folderAnchors.contains(name.lowercased()) { return (current, name) }
            let entries = try children(current)
            let folders = try entries.filter { try kind($0) == .typeDirectory }
            let hasGameContent = entries.contains { entry in
                let key = entry.lastPathComponent.lowercased()
                return folderAnchors.contains(key) || key == "game.ini" || key == "mkxp.json"
                    || ["rgssad", "rgss2a", "rgss3a"].contains(entry.pathExtension.lowercased())
            }
            if hasGameContent
                || (folders.isEmpty
                    && entries.contains { installedNames.contains($0.lastPathComponent.lowercased()) })
            {
                return (current, "")
            }
            guard folders.count == 1 else {
                throw Failure(
                    "Choose the folder containing the game-relative files, such as Data or Graphics.")
            }
            current = folders[0]
        }
    }

    private static func rootIdentity(_ game: URL) throws -> UInt64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: game.path)
        guard let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value else {
            throw Failure("Cannot identify the installed game folder.")
        }
        return inode
    }

    /// Look up the installed spelling once per directory. XP games commonly
    /// ship with Windows casing even when the target volume is case-sensitive.
    private struct Destination {
        let game: URL
        var directories: [URL: [String: URL]] = [:]

        mutating func locate(_ path: String) throws -> (URL, String) {
            var url = game
            var parts = [String]()
            for part in path.components(separatedBy: "/") {
                guard !part.isEmpty, part != ".", part != "..", !part.contains("\\") else {
                    throw Failure("Invalid game-relative path.")
                }
                if FileManager.default.fileExists(atPath: url.path) {
                    guard try GamePatch.kind(url) == .typeDirectory else {
                        throw Failure("File and folder conflict at \(path).")
                    }
                    if directories[url] == nil {
                        var index = [String: URL]()
                        for child in try GamePatch.children(url) {
                            let key = child.lastPathComponent.lowercased()
                            guard index.updateValue(child, forKey: key) == nil else {
                                throw Failure("Ambiguous capitalization in \(url.lastPathComponent).")
                            }
                        }
                        directories[url] = index
                    }
                }
                url = directories[url]?[part.lowercased()] ?? url.appendingPathComponent(part)
                parts.append(url.lastPathComponent)
            }
            return (url, parts.joined(separator: "/"))
        }
    }

    private static func protectedPaths(game: URL, marks: [String]) -> Set<String> {
        let marked = marks.compactMap {
            $0.lowercased().hasPrefix("game/") ? String($0.dropFirst(5)).lowercased() : nil
        }
        return Set(marked).union(PortableGameSaves.entryNames(atGameRoot: game).map { $0.lowercased() })
            .union(reserved)
    }

    private static func protected(_ path: String, in set: Set<String>) -> Bool {
        var rest = path.lowercased()[...]
        while true {
            if set.contains(String(rest)) { return true }
            guard let index = rest.lastIndex(of: "/") else { break }
            rest = rest[..<index]
        }
        let name = (path as NSString).lastPathComponent
        return path.lowercased().split(separator: "/").dropLast().contains {
            PortableGameSaves.saveFolderNames.contains(String($0))
        }
            || (ConcatenatedSaveRecovery.isSaveFilename(name) && RawSaveTransfer.looksLikeSaveSlot(name))
            || PortableGameSaves.hasGenericSaveName(name)
            || (!path.contains("/") && ConcatenatedSaveRecovery.isSaveFilename(name))
    }

    private static func stamp(_ url: URL) throws -> Stamp? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard try kind(url) == .typeRegular else {
            throw Failure("File and folder conflict at \(url.lastPathComponent).")
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return Stamp(
            size: (attrs[.size] as? NSNumber)?.uint64Value ?? 0,
            modified: attrs[.modificationDate] as? Date,
            inode: (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
    }

    public static func prepare(source: URL, game: URL, overlay: URL, marks: [String]) throws -> Review {
        let fm = FileManager.default
        let gameInode = try rootIdentity(game)
        try checkTree(game)
        var paths = protectedPaths(game: game, marks: marks)
        var entries: [(URL, String)] = []
        func walk(_ directory: URL, prefix: String) throws {
            for child in try children(directory) {
                let path = prefix.isEmpty ? child.lastPathComponent : prefix + "/" + child.lastPathComponent
                if try kind(child) == .typeDirectory {
                    try walk(child, prefix: path)
                } else {
                    entries.append((child, path))
                }
            }
        }
        if try kind(source) == .typeDirectory {
            try checkTree(source)
            let (base, prefix) = try root(in: source, game: game)
            if prefix.isEmpty {
                paths.formUnion(PortableGameSaves.entryNames(atGameRoot: base).map { $0.lowercased() })
            }
            try walk(base, prefix: prefix)
        } else {
            let candidates = fm.enumerator(atPath: game.path)
            var matches = [String]()
            while let relative = candidates?.nextObject() as? String {
                let name = (relative as NSString).lastPathComponent
                if name.hasPrefix(".") {
                    candidates?.skipDescendants()
                    continue
                }
                if name.caseInsensitiveCompare(source.lastPathComponent) == .orderedSame,
                    try kind(game.appendingPathComponent(relative)) == .typeRegular
                {
                    matches.append(relative)
                }
            }
            guard matches.count == 1 else {
                throw Failure(
                    "A loose file must match one installed filename. For new or ambiguous files, select a folder with game-relative paths."
                )
            }
            entries = [(source, matches[0])]
        }
        try fm.createDirectory(at: overlay, withIntermediateDirectories: false)
        var destination = Destination(game: game)
        var visited = Set<String>()
        var stamps = [String: Stamp]()
        var added = [String]()
        var kept = [String]()
        for (input, rawPath) in entries {
            let (target, path) = try destination.locate(rawPath)
            if protected(path, in: paths) {
                kept.append(path)
                continue
            }
            guard visited.insert(path.lowercased()).inserted else {
                throw Failure("Duplicate patch path \(path).")
            }
            let output = overlay.appendingPathComponent(path)
            try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: input, to: output)
            if let previous = try stamp(target) { stamps[path] = previous } else { added.append(path) }
        }
        guard !visited.isEmpty else { throw Failure("The selection contains no installable game files.") }
        return Review(
            added: added.sorted(), replaced: stamps.keys.sorted(), preserved: kept.sorted(),
            stamps: stamps, overlay: overlay, game: game, gameInode: gameInode)
    }

    public static func apply(
        _ review: Review, game: URL, marks: [String], backup: URL? = nil,
        beforeSwap: (URL) throws -> Void = { _ in }
    ) throws {
        guard game == review.game, try rootIdentity(game) == review.gameInode else {
            throw Failure("Select the patch for this game again.")
        }
        try checkTree(game)
        let paths = protectedPaths(game: game, marks: marks)
        var destination = Destination(game: game)
        for path in review.added + review.replaced {
            let (target, actualPath) = try destination.locate(path)
            guard !protected(path, in: paths), actualPath == path, try stamp(target) == review.stamps[path]
            else {
                throw Failure("Installed files changed since preview. Select the patch again.")
            }
        }
        // A patched asset may contain progress in an undocumented fork. Keep every
        // displaced original, including files with no recognizable save signature.
        if let backup, !review.replaced.isEmpty {
            let fm = FileManager.default
            try fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createDirectory(at: backup, withIntermediateDirectories: false)
            do {
                for path in review.replaced {
                    let copy = backup.appendingPathComponent(path)
                    try fm.createDirectory(
                        at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.copyItem(at: game.appendingPathComponent(path), to: copy)
                }
            } catch {
                try? fm.removeItem(at: backup)
                throw error
            }
        }
        try GameTreeUpdate.stageAndSwap(newTree: review.overlay, over: game, beforeSwap: beforeSwap)
    }
}
