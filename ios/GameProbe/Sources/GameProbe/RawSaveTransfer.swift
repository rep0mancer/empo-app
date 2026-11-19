// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Copies the game's RGSS save bytes. Never deserializes Ruby objects supplied by another app.
public struct RawSaveTransfer: Sendable {
    public enum Location: String, Codable, Sendable { case shared, portable }
    public enum GameLayout: Sendable { case essentials, standardXP, unknown }

    /// A remembered manual choice is authoritative. Without one, demonstrated slots
    /// outrank engine conventions. Mixed evidence needs an explicit choice.
    public static func suggestedDirectory(
        knownSlotDirectories: Set<String>, manualChoice: String?, layout: GameLayout,
        sharedRoot: String?, portableRoot: String
    ) -> String? {
        if let manualChoice { return manualChoice }
        if !knownSlotDirectories.isEmpty {
            return knownSlotDirectories.count == 1 ? knownSlotDirectories.first : nil
        }
        switch layout {
        case .essentials: return sharedRoot
        case .standardXP: return portableRoot
        case .unknown: return nil
        }
    }

    /// Same fallback as the engine launch when a required folder cannot be made.
    /// Merely viewing the transfer sheet must not create the shared tree.
    public static func prospectiveSharedDirectory(_ resolved: URL?, fallback: URL) -> URL? {
        guard let resolved else { return nil }
        var current = resolved
        let fm = FileManager.default
        var directory: ObjCBool = false
        while !fm.fileExists(atPath: current.path, isDirectory: &directory) {
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { return fallback }
            current = parent
        }
        guard directory.boolValue, current.path == resolved.path || fm.isWritableFile(atPath: current.path)
        else { return fallback }
        return resolved
    }
    public struct Staged: Sendable {
        public let directory: URL
        public let paths: [String]
        public let skipped: Int
    }
    public struct Change: Codable, Sendable {
        public let path: String
        public let previous: String?
        let incoming: String
        public var isIdentical: Bool { previous == incoming }
    }
    public struct Plan: Sendable {
        let source: URL
        let journal: Journal
        public var changes: [Change] { journal.changes }
    }
    struct Journal: Codable, Sendable {
        let location: Location
        let directory: String
        let rootPath: String
        let backup: UUID
        let changes: [Change]
    }
    public struct Failure: LocalizedError {
        public let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
    private let game: URL
    private let shared: URL?
    private let state: URL
    private let backups: URL
    private let marked: Set<String>
    private let scriptFiles: Set<String>
    private var fm: FileManager { .default }
    private var documents: URL {
        game.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private var pending: URL { state.appendingPathComponent("pending-raw-save-import.json") }

    public init(game: URL, shared: URL?, state: URL, backups: URL, markedPortableFiles: [String] = []) {
        self.game = game
        self.shared = shared
        self.state = state
        self.backups = backups
        let scripts = [
            GameINI.parseINIValue(at: game, section: "game", key: "scripts"),
            ManagedMkxpConfig.loadBaseDict(from: game)?["customScript"] as? String,
        ]
        self.scriptFiles = Set(
            scripts.compactMap { $0?.replacingOccurrences(of: "\\", with: "/").lowercased() })
        self.marked = Set(
            markedPortableFiles.compactMap { path in
                guard path.hasPrefix("Game/") else { return nil }
                let relative = String(path.dropFirst(5))
                return Self.cleanPath(relative) ? relative : nil
            })
    }

    private static let assetFolders: Set<String> = [
        "data", "graphics", "audio", "fonts", "system", "movies", "scripts", "plugins", "metadata",
        "empostate",
    ]
    private static let databaseNames: Set<String> = [
        "actors", "animations", "armors", "classes", "commonevents", "enemies", "items", "mapinfos",
        "scripts", "skills", "states", "system", "tilesets", "troops", "weapons", "trainers", "species",
        "moves", "abilities", "types", "encounters", "metadata",
    ]

    private static func safePart(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\")
            && !name.contains(":")
            && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    private static func usableDirectory(_ name: String) -> Bool {
        safePart(name) && !assetFolders.contains(name.lowercased())
    }
    private static func isSaveName(_ name: String) -> Bool {
        guard safePart(name) else { return false }
        var n = name.lowercased()
        while n.hasSuffix(".bak") { n.removeLast(4) }
        guard n.hasSuffix(".rxdata") else { return false }
        let stem = String(n.dropLast(7))
        return !stem.isEmpty && !databaseNames.contains(stem)
            && !(stem.hasPrefix("map") && !stem.dropFirst(3).isEmpty
                && stem.dropFirst(3).allSatisfy(\.isNumber))
    }
    static func looksLikeSaveSlot(_ name: String) -> Bool {
        let stem = name.lowercased().components(separatedBy: ".")[0]
        return stem == "game" || stem.hasPrefix("save") || stem.hasPrefix("game_") || stem.hasPrefix("game-")
            || stem.hasPrefix("autosave")
            || (stem.hasPrefix("game") && stem.dropFirst(4).allSatisfy(\.isNumber))
    }
    private static func conventional(_ folder: String) -> Bool {
        ["save", "saves", "savedata", "savegame", "savegames", "savedgames", "savefiles"].contains(
            folder.lowercased().filter { $0.isLetter })
    }
    private static func kind(_ url: URL) throws -> FileAttributeType? {
        do {
            return try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain
            && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
        { return nil }
    }
    private static func cleanDirectory(_ path: String) -> Bool {
        path.isEmpty || path.components(separatedBy: "/").allSatisfy(usableDirectory)
    }
    private static func cleanPath(_ path: String) -> Bool {
        let parts = path.components(separatedBy: "/")
        return parts.dropLast().allSatisfy(usableDirectory) && parts.last.map(isSaveName) == true
    }
    /// Verify each traversed component, including user-editable roots in Files.
    private func validate(_ url: URL, under root: URL) throws {
        let path = url.standardizedFileURL.path
        let base = root.standardizedFileURL.path
        guard path == base || path.hasPrefix(base + "/") else {
            throw Failure("Path is outside this game's storage.")
        }
        var current = root
        for part in path.dropFirst(base.count).split(separator: "/") {
            current.appendPathComponent(String(part))
            if try Self.kind(current) == .typeSymbolicLink {
                throw Failure("Move the save out of the linked folder at \(current.lastPathComponent).")
            }
        }
    }
    private func root(_ location: Location) throws -> URL {
        guard let url = location == .shared ? shared : game else {
            throw Failure("This game has no shared save folder.")
        }
        try validate(url, under: documents)
        return url
    }
    private static func hasHeader(_ file: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        return try handle.read(upToCount: 2) == Data([4, 8])
    }
    private static func walk(
        _ folder: URL, prefix: String = "", visit: (URL, String, FileAttributeType) throws -> Bool
    ) throws {
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() {
            let path = prefix.isEmpty ? name : prefix + "/" + name
            let file = folder.appendingPathComponent(name)
            guard let type = try kind(file) else { throw Failure("A file disappeared: \(path)") }
            if try visit(file, path, type), type == .typeDirectory {
                try walk(file, prefix: path, visit: visit)
            }
        }
    }
    public func portableDirectories() throws -> Set<String> {
        let base = try root(.portable)
        // A game may create Save Data only on its first save. Offer it explicitly
        // without inferring that an empty game actually uses portable mode.
        var folders: Set<String> = ["Saves", "Save Data"]
        for name in try fm.contentsOfDirectory(atPath: base.path) where Self.usableDirectory(name) {
            let folder = base.appendingPathComponent(name)
            if Self.conventional(name), try Self.kind(folder) == .typeDirectory { folders.insert(name) }
        }
        return folders
    }

    /// Existing .rxdata in the game root can also be maps or game databases. Inside the
    /// game tree descend only into conventional save folders, and recognize bare slot names.
    public func files(in location: Location) throws -> [String] {
        let base = try root(location)
        guard try Self.kind(base) == .typeDirectory else { return [] }
        var result: [String] = []
        try Self.walk(base) { file, path, kind in
            let name = file.lastPathComponent
            if kind == .typeDirectory {
                return Self.usableDirectory(name)
                    && (location == .shared || path.contains("/") || Self.conventional(name))
            }
            if kind == .typeRegular, Self.cleanPath(path),
                location == .shared || path.contains("/") || Self.looksLikeSaveSlot(name),
                try Self.hasHeader(file)
            {
                result.append(path)
            }
            return false
        }
        if location == .portable {
            for path in marked where !result.contains(path) {
                let file = base.appendingPathComponent(path)
                try validate(file, under: documents)
                if try Self.kind(file) == .typeRegular, try Self.hasHeader(file) { result.append(path) }
            }
        }
        return result.filter { location != .portable || !scriptFiles.contains($0.lowercased()) }.sorted()
    }

    /// Call while each selected Files URL is security-scoped and coordinated. Staging
    /// freezes the actual bytes for review before the picker releases access.
    public static func stage(_ sources: [URL], at staging: URL) throws -> Staged {
        let fm = FileManager.default
        guard try kind(staging) == nil else { throw Failure("Import staging already exists.") }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        var paths: [String] = []
        var skipped = 0
        var names: Set<String> = []
        func copy(_ file: URL, _ path: String, _ type: FileAttributeType) throws -> Bool {
            if type == .typeDirectory, usableDirectory(file.lastPathComponent) { return true }
            guard type == .typeRegular, cleanPath(path) else {
                skipped += 1
                return false
            }
            guard try hasHeader(file) else {
                throw Failure("\(path) is missing the RPG Maker XP save header.")
            }
            guard names.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted else {
                throw Failure("More than one selected save uses \(path).")
            }
            let to = staging.appendingPathComponent(path)
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: file, to: to)
            paths.append(path)
            return false
        }
        do {
            for url in sources {
                if try kind(url) == .typeDirectory {
                    guard sources.count == 1, usableDirectory(url.lastPathComponent) else {
                        throw Failure(
                            "Select one save folder or individual save files. Game asset folders cannot be imported."
                        )
                    }
                    try walk(url, visit: copy)
                } else {
                    guard try kind(url) == .typeRegular, isSaveName(url.lastPathComponent) else {
                        throw Failure("Choose an RPG Maker XP .rxdata save file.")
                    }
                    _ = try copy(url, url.lastPathComponent, .typeRegular)
                }
            }
            guard !paths.isEmpty else { throw Failure("The selection contains no RPG Maker XP save files.") }
            return Staged(directory: staging, paths: paths.sorted(), skipped: skipped)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    /// Export a standalone file, or a ZIP whose paths are relative to the selected
    /// save directory. Both forms contain the original bytes and slot filenames.
    public func export(
        location: Location, directory: String = "", file: String? = nil, into staging: URL
    ) throws -> URL {
        guard Self.cleanDirectory(directory) else { throw Failure("Invalid save directory.") }
        let base = try root(location)
        let prefix = directory.isEmpty ? "" : directory + "/"
        let members = try files(in: location).filter { $0.hasPrefix(prefix) }
        guard !members.isEmpty else { throw Failure("This directory contains no XP saves.") }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        if let file {
            guard members.contains(file) else { throw Failure("The selected save is no longer present.") }
            let source = base.appendingPathComponent(file)
            try validate(source, under: documents)
            let dest = staging.appendingPathComponent(source.lastPathComponent)
            try fm.copyItem(at: source, to: dest)
            return dest
        }
        let archive = staging.appendingPathComponent(
            game.deletingLastPathComponent().lastPathComponent + " Saves.zip")
        let writer = try ZipWriter(creating: archive)
        for path in members {
            let source = base.appendingPathComponent(path)
            try validate(source, under: documents)
            try writer.add(file: source, at: String(path.dropFirst(prefix.count)))
        }
        try writer.finish()
        return archive
    }

    public func plan(_ staged: Staged, location: Location, directory: String = "") throws -> Plan {
        guard Self.cleanDirectory(directory) else { throw Failure("Invalid save folder.") }
        let base = try root(location)
        var changes: [Change] = []
        for path in staged.paths {
            let relative = directory.isEmpty ? path : directory + "/" + path
            try checkSlot(relative, location: location)
            let output = base.appendingPathComponent(relative)
            try validate(output, under: base)
            let original = try digest(output)
            let incoming = try ContentHash.hexOfFile(at: staged.directory.appendingPathComponent(path))
            changes.append(Change(path: path, previous: original, incoming: incoming))
        }
        return Plan(
            source: staged.directory,
            journal: Journal(
                location: location, directory: directory,
                rootPath: String(base.path.dropFirst(documents.path.count + 1)), backup: UUID(),
                changes: changes))
    }
    private func checkSlot(_ path: String, location: Location) throws {
        let parts = path.components(separatedBy: "/")
        guard Self.cleanPath(path), location != .portable || !scriptFiles.contains(path.lowercased()),
            location == .shared || marked.contains(path)
                || (parts.count == 1 ? Self.looksLikeSaveSlot(parts[0]) : Self.conventional(parts[0]))
        else {
            throw Failure(
                "\(path) is outside a recognized portable save slot. Choose the matching save folder or use Files to review this title's custom layout."
            )
        }
    }
    private func digest(_ file: URL) throws -> String? {
        guard let type = try Self.kind(file) else { return nil }
        guard type == .typeRegular, try Self.hasHeader(file) else {
            throw Failure(
                "\(file.lastPathComponent) already exists and is not a recognized XP save. It was kept.")
        }
        return try ContentHash.hexOfFile(at: file)
    }
    private func originalFolder(_ journal: Journal) -> URL {
        backups.appendingPathComponent(journal.backup.uuidString)
    }
    private func target(_ change: Change, _ journal: Journal) throws -> URL {
        guard Self.cleanDirectory(journal.directory) else {
            throw Failure("Invalid save folder in the import record.")
        }
        let path = journal.directory.isEmpty ? change.path : journal.directory + "/" + change.path
        try checkSlot(path, location: journal.location)
        let base = try root(journal.location)
        let recorded = documents.appendingPathComponent(journal.rootPath).standardizedFileURL
        // Changing a game’s mkxp.json while Empo is down must not redirect recovery
        // into another game's saves. The fallback UserData path is game-specific.
        let fallback = game.deletingLastPathComponent().appendingPathComponent("UserData")
        guard
            recorded.path == base.standardizedFileURL.path
                || (journal.location == .shared && recorded.path == fallback.path)
        else {
            throw Failure(
                "The game's save directory changed after the review. Restore its original directory before continuing."
            )
        }
        let url = recorded.appendingPathComponent(path)
        try validate(url, under: documents)
        return url
    }
    public func apply(_ plan: Plan) throws -> URL? {
        try recover()
        let journal = plan.journal
        let backup = originalFolder(journal)
        try validate(backup, under: documents)
        var replaced = false
        let differences = journal.changes.filter { $0.previous != $0.incoming }
        // Recheck every reviewed destination and make all backups before touching live files.
        for change in journal.changes {
            let dest = try target(change, journal)
            guard try digest(dest) == change.previous else {
                throw Failure("\(change.path) changed. Review the import again.")
            }
            if change.previous != nil, change.previous != change.incoming {
                let copy = backup.appendingPathComponent(change.path)
                try fm.createDirectory(
                    at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: dest, to: copy)
                let backupFile = try FileHandle(forWritingTo: copy)
                defer { try? backupFile.close() }
                try backupFile.synchronize()
                guard try ContentHash.hexOfFile(at: copy) == change.previous else {
                    throw Failure("The backup of \(change.path) could not be verified.")
                }
                replaced = true
            }
        }
        guard !differences.isEmpty else { return nil }
        try validate(pending, under: documents)
        try fm.createDirectory(at: state, withIntermediateDirectories: true)
        let record = try JSONEncoder().encode(journal)
        if replaced { try record.write(to: backup.appendingPathComponent("import.json"), options: .atomic) }
        try record.write(to: pending, options: .atomic)
        do {
            for change in differences {
                let dest = try target(change, journal)
                guard try digest(dest) == change.previous else {
                    throw Failure("\(change.path) changed during import.")
                }
                try writeCopy(
                    plan.source.appendingPathComponent(change.path), to: dest, expected: change.incoming)
            }
            try fm.removeItem(at: pending)
            return replaced ? backup : nil
        } catch {
            try recover()
            throw error
        }
    }
    private func writeCopy(_ source: URL, to dest: URL, expected hash: String) throws {
        let parent = dest.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let temp = parent.appendingPathComponent(".empo-save-" + UUID().uuidString)
        defer { try? fm.removeItem(at: temp) }
        try fm.copyItem(at: source, to: temp)
        guard try ContentHash.hexOfFile(at: temp) == hash else {
            throw Failure("The copy of \(dest.lastPathComponent) could not be verified.")
        }
        if try Self.kind(dest) != nil {
            _ = try fm.replaceItemAt(dest, withItemAt: temp)
        } else {
            try fm.moveItem(at: temp, to: dest)
        }
    }
    /// Before the next game launch, roll back a process death between individual atomic writes.
    /// A later external edit is never clobbered by rollback.
    public func recover() throws {
        try validate(pending, under: documents)
        guard try Self.kind(pending) != nil else { return }
        let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: pending))
        let backup = originalFolder(journal)
        for change in journal.changes.reversed() where change.incoming != change.previous {
            let file = try target(change, journal)
            let current = try digest(file)
            if current == change.previous { continue }
            guard current == change.incoming else {
                throw Failure(
                    "\(change.path) changed outside Empo during recovery. Its copies were kept in Save Import Backups."
                )
            }
            if let original = change.previous {
                let copy = backup.appendingPathComponent(change.path)
                try validate(copy, under: documents)
                try writeCopy(copy, to: file, expected: original)
            } else {
                try fm.removeItem(at: file)
            }
        }
        try fm.removeItem(at: pending)
    }
}
