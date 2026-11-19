// SPDX-License-Identifier: GPL-3.0-only
#if os(iOS)
import SwiftUI
import Translation

struct DialogueTranslationSettings: View {
    let model: GameSettingsModel

    var body: some View {
        Section {
            Picker(
                "Translate dialogue",
                selection: Binding(
                    get: { model.settings.dialogueTranslationSource ?? "" },
                    set: { model.settings.dialogueTranslationSource = $0.isEmpty ? nil : $0 }
                )
            ) {
                Text("Off").tag("")
                Text("Spanish → German").tag("es")
                Text("English → German").tag("en")
            }
            .accessibilityIdentifier("translation.language")
            if let source = model.settings.dialogueTranslationSource, ["es", "en"].contains(source) {
                DialogueLanguageDownload(source: source).id(source)
            }
        } header: {
            Text("Dialogue translation")
        } footer: {
            Text("Show German text in the game’s dialogue boxes. Applies when you next launch this game.")
        }
    }
}

private struct DialogueLanguageDownload: View {
    let source: String
    @State private var availability: LanguageAvailability.Status?
    @State private var configuration: TranslationSession.Configuration?
    @State private var downloading = false
    @State private var downloadError: String?
    @Environment(\.scenePhase) private var scenePhase

    private var from: Locale.Language { Locale.Language(identifier: source) }
    private let german = Locale.Language(identifier: "de")

    var body: some View {
        Group {
            if downloading {
                ProgressView("Preparing languages…")
            } else if availability == .installed {
                Label("Ready for offline translation", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else if availability == .supported {
                Button {
                    downloading = true
                    downloadError = nil
                    configuration = .init(source: from, target: german)
                } label: {
                    Label("Download languages…", systemImage: "arrow.down.circle")
                }
                .accessibilityIdentifier("translation.download")
            } else if availability == .unsupported {
                Text("This language pair is unavailable on this device.")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView("Checking languages…")
            }
            if let downloadError {
                Text(verbatim: downloadError).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await refreshAvailability()
        }
        .translationTask(configuration) { session in
            do {
                try await session.prepareTranslation()
            } catch {
                guard !Task.isCancelled else { return }
                downloadError = error.localizedDescription
            }
            guard !Task.isCancelled else { return }
            await refreshAvailability()
            downloading = false
            configuration = nil
        }
    }

    private func refreshAvailability() async {
        let status = await LanguageAvailability().status(from: from, to: german)
        if !Task.isCancelled { availability = status }
    }
}
#endif
