// SPDX-License-Identifier: GPL-3.0-only
#if os(iOS)
import Foundation
import GameProbe
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum GameRawSaves {
    static var isTransferring = false

    static func sharedDirectory(_ container: GameContainer, core: any GameCore) -> URL? {
        RawSaveTransfer.prospectiveSharedDirectory(
            DataDirectory.resolve(for: container, core: core), fallback: container.userDataURL)
    }

    static func layout(_ container: GameContainer) -> RawSaveTransfer.GameLayout {
        if PokemonEssentialsDetection.detect(in: container.gameURL, stateDirectory: container.empoStateURL) {
            return .essentials
        }
        let hasCustomData = ManagedMkxpConfig.readDataPath(
            stateDirectory: container.empoStateURL, gameDirectory: container.gameURL
        ).isDeclared
        let script = GameINI.parseINIValue(at: container.gameURL, section: "game", key: "scripts")?
            .replacingOccurrences(of: "\\", with: "/").lowercased()
        return !hasCustomData && script == "data/scripts.rxdata" ? .standardXP : .unknown
    }

    static func transfer(_ container: GameContainer, shared: URL?) -> RawSaveTransfer {
        return RawSaveTransfer(
            game: container.gameURL, shared: shared, state: container.empoStateURL,
            backups: DataDirectory.documentsRootURL.appendingPathComponent("Save Import Backups")
                .appendingPathComponent(container.folderName),
            markedPortableFiles: (try? GameBackupIntent.load(from: container.empoStateURL).manualMarks) ?? [])
    }

    /// The recovery path must run before legacy migrations or a game can read the first half of an interrupted import.
    static func recover(_ container: GameContainer, core: any GameCore) throws {
        guard !isTransferring else {
            throw GameStart.Failure(
                errorDescription: String(
                    localized: "Wait for the save transfer to finish before starting a game."))
        }
        let record = container.empoStateURL.appendingPathComponent("pending-raw-save-import.json")
        guard FileManager.default.fileExists(atPath: record.path) else { return }
        let shared = sharedDirectory(container, core: core)
        try transfer(container, shared: shared).recover()
    }
}

private struct SaveDestination: Hashable, Identifiable {
    let location: RawSaveTransfer.Location
    let folder: String
    let root: String
    var title: String { folder.isEmpty ? root : root + "/" + folder }
    var id: String { title }
}

private final class RawSaveScratch {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    deinit { try? FileManager.default.removeItem(at: url) }
}

struct RawSaveTransferView: View {
    let container: GameContainer
    @State private var transfer: RawSaveTransfer?
    @State private var destinations: [SaveDestination] = []
    @State private var selected: SaveDestination?
    @State private var filesByLocation: [RawSaveTransfer.Location: [String]] = [:]
    @State private var picking = false
    @State private var importFolder = false
    @State private var staged: RawSaveTransfer.Staged?
    @State private var plan: RawSaveTransfer.Plan?
    @State private var export: PickedPackage?
    @State private var routingHint = ""
    @State private var message: String?
    @State private var busy = false
    @State private var confirm = false
    @State private var workspace = RawSaveScratch()
    private var scratch: URL { workspace.url }

    private var preference: String { "rawSaveDirectory." + container.folderName }
    private var listed: [String] {
        guard let selected else { return [] }
        let prefix = selected.folder.isEmpty ? "" : selected.folder + "/"
        return (filesByLocation[selected.location] ?? []).filter { $0.hasPrefix(prefix) }
    }

    var body: some View {
        Form {
            Section {
                Picker(
                    "Save directory",
                    selection: Binding(
                        get: { selected },
                        set: { value in
                            selected = value
                            UserDefaults.standard.set(value?.id, forKey: preference)
                            routingHint =
                                value == nil
                                ? "Choose where this game reads its active save."
                                : "Using your selected save directory."
                        })
                ) {
                    Text("Choose a directory").tag(nil as SaveDestination?)
                    ForEach(destinations) { row in Text(row.title).tag(Optional(row)) }
                }
                .pickerStyle(.navigationLink)
                if let selected { Text(selected.title).font(.caption.monospaced()).textSelection(.enabled) }
            } footer: {
                Text(
                    routingHint
                        + " If you're unsure, make an in-game save, close the game and check its location.")
            }
            Section("Import") {
                Button("Choose save files…") {
                    importFolder = false
                    picking = true
                }
                Button("Choose a save folder…") {
                    importFolder = true
                    picking = true
                }
                if let staged {
                    if staged.skipped > 0 {
                        Text("Skipped entries outside the XP save format: \(staged.skipped)").font(.footnote)
                    }
                    ForEach(staged.paths, id: \.self) { path in
                        HStack {
                            Text(path)
                            Spacer()
                            if let row = plan?.changes.first(where: { $0.path == path }) {
                                Text(row.isIdentical ? "Identical" : row.previous == nil ? "New" : "Replace")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button("Import reviewed saves") { confirm = true }.disabled(plan == nil)
                }
            }
            Section("Export") {
                if listed.isEmpty {
                    Text("No XP saves in the selected directory.").foregroundStyle(.secondary)
                }
                ForEach(listed, id: \.self) { file in Button(file) { exportSave(file) } }
                if !listed.isEmpty { Button("Export directory as ZIP…") { exportSave(nil) } }
            }
            if busy { ProgressView() }
            if let message { Text(message).textSelection(.enabled) }
        }
        .navigationTitle("Import / Export Save")
        .disabled(busy)
        .task { refresh() }
        .onChange(of: selected) { _, _ in review() }
        .fileImporter(
            isPresented: $picking, allowedContentTypes: importFolder ? [.folder] : [.data],
            allowsMultipleSelection: !importFolder
        ) { result in
            switch result {
            case .success(let urls): importFiles(urls)
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { message = error.localizedDescription }
            }
        }
        .confirmationDialog(
            "Import saves into \(selected?.title ?? "")?", isPresented: $confirm, titleVisibility: .visible
        ) {
            Button("Import saves") { apply() }
        } message: {
            Text("Empo backs up each existing save before replacing it. New slots keep their filenames.")
        }
        .sheet(
            item: $export,
            onDismiss: { try? FileManager.default.removeItem(at: scratch.appendingPathComponent("Export")) }
        ) { item in
            PackageExportPicker(file: item.url) { saved in
                export = nil
                if saved { message = "Saved to Files." }
            }
        }
    }

    private func ready() -> Bool {
        if BackupDeviceConditions.isSessionLive {
            message =
                "Close the game completely before transferring saves. A paused game still has its saves open."
            return false
        }
        if GameRawSaves.isTransferring {
            message = "Another save transfer is running."
            return false
        }
        if RestoreCoordinator.shared.isRestoring {
            message = "Wait for the current restore to finish."
            return false
        }
        return true
    }
    private func refresh() {
        guard ready(), let core = GameCores.core(forGameAt: container.gameURL) else { return }
        do {
            try GameRawSaves.recover(container, core: core)
            let shared = GameRawSaves.sharedDirectory(container, core: core)
            let service = GameRawSaves.transfer(container, shared: shared)
            transfer = service
            var rows: [SaveDestination] = []
            var occupied: [SaveDestination] = []
            for (location, url) in [
                (RawSaveTransfer.Location.shared, shared), (.portable, container.gameURL),
            ] {
                guard let url else { continue }
                let root = String(url.path.dropFirst(DataDirectory.documentsRootURL.path.count + 1))
                let files = try service.files(in: location)
                filesByLocation[location] = files
                let folders = Set(files.map { ($0 as NSString).deletingLastPathComponent })
                var choices = folders.union([""])
                if location == .portable { choices.formUnion(try service.portableDirectories()) }
                for folder in choices.sorted() {
                    let row = SaveDestination(location: location, folder: folder, root: root)
                    rows.append(row)
                    if folders.contains(folder) { occupied.append(row) }
                }
            }
            destinations = rows
            let manual = rows.first { $0.id == UserDefaults.standard.string(forKey: preference) }
            let sharedRoot = rows.first { $0.location == .shared && $0.folder.isEmpty }?.id
            let portableRoot = rows.first { $0.location == .portable && $0.folder.isEmpty }?.id ?? ""
            let layout = GameRawSaves.layout(container)
            let proposed = RawSaveTransfer.suggestedDirectory(
                knownSlotDirectories: Set(occupied.map(\.id)), manualChoice: manual?.id,
                layout: layout, sharedRoot: sharedRoot, portableRoot: portableRoot)
            selected = rows.first { $0.id == proposed }
            if manual != nil {
                routingHint = "Using your selected save directory."
            } else if occupied.count == 1 {
                routingHint = "This directory already contains the game's save files."
            } else if occupied.count > 1 {
                routingHint = "Saves exist in more than one directory. Choose the one this game uses."
            } else if selected == nil {
                routingHint = "No slots identify the active directory yet. Choose a destination."
            } else if layout == .essentials {
                routingHint = "No slots yet. The shared directory is suggested for Pokémon Essentials."
            } else {
                routingHint =
                    "No slots yet. The game folder is suggested for a standard RPG Maker XP project."
            }

        } catch { message = error.localizedDescription }
    }
    private func review() {
        plan = nil
        guard let staged, let selected, let transfer, ready() else { return }
        do {
            plan = try transfer.plan(staged, location: selected.location, directory: selected.folder)
            message = nil
        } catch { message = error.localizedDescription }
    }
    private func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty, ready() else { return }
        if let staged { try? FileManager.default.removeItem(at: staged.directory) }
        staged = nil
        plan = nil
        busy = true
        let folder = scratch.appendingPathComponent(UUID().uuidString)
        Task {
            defer { busy = false }
            do {
                let result = try await Self.readFiles(urls, stage: folder)
                staged = result
                if selected == nil { message = "Choose the destination before importing." }
                review()
            } catch { message = error.localizedDescription }
        }
    }
    nonisolated private static func readFiles(
        _ urls: [URL], stage: URL
    ) async throws -> RawSaveTransfer.Staged {
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { for url in scoped { url.stopAccessingSecurityScopedResource() } }
        let intents = urls.map { NSFileAccessIntent.readingIntent(with: $0, options: .withoutChanges) }
        // A File Provider may materialize a selection at another URL. One batch acquires
        // all the coordinated reads in the order chosen by the provider.
        return try await withCheckedThrowingContinuation { continuation in
            NSFileCoordinator().coordinate(with: intents, queue: OperationQueue()) { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(with: Result { try RawSaveTransfer.stage(intents.map(\.url), at: stage) })
            }
        }
    }
    private func apply() {
        guard let transfer, let plan, ready() else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            await BackupScheduler.shared.withRunsHeld {
                guard ready() else { return }
                GameRawSaves.isTransferring = true
                let result = await Task.detached { Result { try transfer.apply(plan) } }.value
                GameRawSaves.isTransferring = false
                do {
                    let backup = try result.get()
                    BackupScheduler.shared.markDirty(container: container)
                    if let staged { try? FileManager.default.removeItem(at: staged.directory) }
                    staged = nil
                    self.plan = nil
                    refresh()
                    message =
                        backup.map {
                            "Imported. Previous files: Save Import Backups/\(container.folderName)/\($0.lastPathComponent)"
                        } ?? "Imported. The save files are ready to use."
                } catch {
                    self.plan = nil
                    message = error.localizedDescription
                }
            }
        }
    }
    private func exportSave(_ file: String?) {
        guard let transfer, let selected, ready() else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            let folder = scratch.appendingPathComponent("Export").appendingPathComponent(UUID().uuidString)
            await BackupScheduler.shared.withRunsHeld {
                guard ready() else { return }
                GameRawSaves.isTransferring = true
                defer { GameRawSaves.isTransferring = false }
                do {
                    let url = try await Task.detached {
                        try transfer.export(
                            location: selected.location, directory: selected.folder, file: file, into: folder)
                    }.value
                    export = PickedPackage(url: url)
                } catch { message = error.localizedDescription }
            }
        }
    }
}
#endif
