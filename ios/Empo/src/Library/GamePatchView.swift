// SPDX-License-Identifier: GPL-3.0-only
#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

struct GamePatchView: View {
    let game: GameEntry

    private struct Selection: Equatable {
        let url: URL
        let isFolder: Bool
    }

    @State private var picking = false
    @State private var pickFolder = false
    @State private var selection: Selection?
    @State private var review: GamePatchReview?
    @State private var sourceName = ""
    @State private var confirming = false
    @State private var applying = false
    @State private var applied = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if applying {
                ProgressView("Applying patch…")
            } else if selection != nil {
                ProgressView("Preparing preview…")
            } else if let review {
                Section {
                    if !review.added.isEmpty || !review.replaced.isEmpty {
                        Button("Apply patch…") { confirming = true }
                            .confirmationDialog(
                                "Apply patch to \(game.title)?", isPresented: $confirming,
                                titleVisibility: .visible
                            ) {
                                Button("Apply patch", role: review.replaced.isEmpty ? nil : .destructive) {
                                    apply(review)
                                }
                                Button("Cancel", role: .cancel) {}
                            }
                    } else {
                        Text("This patch contains no files to install.")
                    }
                    Button("Discard preview") { discardPreview() }
                } header: {
                    Text(verbatim: sourceName)
                }
                paths(review.added, title: "Files to add")
                paths(review.replaced, title: "Files to replace")
                paths(review.preserved, title: "Protected files kept")
            } else {
                Section {
                    Button("Choose a patch file…") { choose(folder: false) }
                    Button("Choose a patch folder…") { choose(folder: true) }
                } header: {
                    Text(verbatim: game.title)
                } footer: {
                    Text("Choose a ZIP, 7z or RAR archive, a replacement asset, or a folder.")
                }
            }
            if applied {
                Label("Patch applied.", systemImage: "checkmark.circle")
            }
            if let errorMessage {
                Label {
                    Text(verbatim: errorMessage).textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.circle")
                }
            }
        }
        .navigationTitle("Install game patch")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(applying)
        .interactiveDismissDisabled(applying)
        .fileImporter(isPresented: $picking, allowedContentTypes: pickFolder ? [.folder] : [.data]) {
            result in
            switch result {
            case .success(let url):
                applied = false
                errorMessage = nil
                selection = Selection(url: url, isFolder: pickFolder)
            case .failure(let error):
                let nsError = error as NSError
                if nsError.domain != NSCocoaErrorDomain || nsError.code != NSUserCancelledError {
                    errorMessage = error.localizedDescription
                }
            }
        }
        .task(id: selection) {
            guard let selected = selection else { return }
            do {
                let prepared = try await GamePatchInstaller.prepare(
                    file: selected.url, isFolder: selected.isFolder, game: game)
                guard !Task.isCancelled else {
                    GamePatchInstaller.discard(prepared)
                    return
                }
                review = prepared
                sourceName = selected.url.lastPathComponent
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
            selection = nil
        }
        .onDisappear {
            selection = nil
            discardPreview()
        }
    }

    @ViewBuilder private func paths(_ entries: [String], title: LocalizedStringKey) -> some View {
        if !entries.isEmpty {
            Section {
                ForEach(entries, id: \.self) { path in
                    Text(verbatim: path).textSelection(.enabled)
                }
            } header: {
                HStack {
                    Text(title)
                    Spacer()
                    Text(entries.count, format: .number)
                }
            }
        }
    }

    private func choose(folder: Bool) {
        pickFolder = folder
        picking = true
    }

    private func discardPreview() {
        if let review { GamePatchInstaller.discard(review) }
        review = nil
    }

    private func apply(_ prepared: GamePatchReview) {
        guard !applying else { return }
        // Applying takes ownership of this stage through completion, even if the sheet closes.
        review = nil
        applying = true
        Task { @MainActor in
            defer {
                GamePatchInstaller.discard(prepared)
                applying = false
            }
            do {
                try await GamePatchInstaller.apply(prepared, game: game)
                applied = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
#endif
