// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Translation

/// One provider and one cache per game launch. The engine joins text fragments
/// with a unit separator so a translation cannot reorder choices or game commands.
@MainActor
final class DialogueTranslationService {
    typealias Translate = @MainActor ([String]) async throws -> [String]
    typealias Reply = @MainActor (UInt64, String?) -> Void

    private let translate: Translate
    private let cancelProvider: @MainActor () -> Void
    private let reply: Reply
    private let byteLimit: Int
    private let providerTimeout: Duration
    private let cache = NSCache<NSString, NSString>()
    private var active: (job: UInt64, ticket: UInt64, input: String)?
    private var worker: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var stopped = false

    init(
        byteLimit: Int, providerTimeout: Duration = .seconds(5),
        translate: @escaping Translate, cancelProvider: @escaping @MainActor () -> Void = {},
        reply: @escaping Reply
    ) {
        self.byteLimit = byteLimit
        self.providerTimeout = providerTimeout
        self.translate = translate
        self.cancelProvider = cancelProvider
        self.reply = reply
        cache.countLimit = 512
        cache.totalCostLimit = 1024 * 1024
    }

    convenience init?(source: String?, byteLimit: Int, reply: @escaping Reply) {
        guard let source, source == "es" || source == "en" else { return nil }
        let provider = AppleDialogueTranslator(source: source)
        self.init(
            byteLimit: byteLimit, translate: { try await provider.translate($0) },
            cancelProvider: { provider.reset() }, reply: reply)
    }

    func receive(_ ticket: UInt64, input: String) {
        guard !stopped else { return }
        guard !input.isEmpty, input.utf8.count <= byteLimit, !input.utf8.contains(0) else {
            reply(ticket, nil)
            return
        }
        let fragments = input.components(separatedBy: "\u{1f}")
        guard fragments.count <= 128 else {
            reply(ticket, nil)
            return
        }
        var values = [String: String]()
        var missing = [String]()
        var seen = Set<String>()
        for text in fragments where seen.insert(text).inserted {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                values[text] = text
            } else if let hit = cache.object(forKey: text as NSString) {
                values[text] = hit as String
            } else {
                missing.append(text)
            }
        }
        guard !missing.isEmpty else {
            reply(ticket, packed(fragments, values: values))
            return
        }

        // The engine may time out on cold model startup before Apple finishes.
        // Share the job if the game asks for the same line again. A different
        // line can immediately use its original text while this job completes.
        if let pending = active {
            if pending.input == input {
                active = (pending.job, ticket, input)
                if ticket != pending.ticket { reply(pending.ticket, nil) }
            } else {
                reply(ticket, nil)
            }
            return
        }

        active = (ticket, ticket, input)
        worker = Task { [weak self, translate] in
            let result = try? await translate(missing)
            guard !Task.isCancelled, let self, self.active?.job == ticket else { return }
            if let result, result.count == missing.count {
                for (text, output) in zip(missing, result) {
                    guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        output.utf8.count <= self.byteLimit, !output.contains("\u{1f}"),
                        !output.utf8.contains(0)
                    else {
                        self.finish(nil)
                        return
                    }
                    values[text] = output
                }
                let translated = self.packed(fragments, values: values)
                if translated != nil {
                    for (text, output) in zip(missing, result) {
                        self.cache.setObject(
                            output as NSString, forKey: text as NSString,
                            cost: text.utf8.count + output.utf8.count)
                    }
                }
                self.finish(translated)
            } else {
                self.finish(nil)
            }
        }
        // The VM has its own shorter deadline. This longer bound lets a cold
        // but successful translation populate the cache for the next message.
        watchdog = Task { [weak self, providerTimeout] in
            do { try await Task.sleep(for: providerTimeout) } catch { return }
            guard let self, self.active?.job == ticket else { return }
            self.worker?.cancel()
            self.cancelProvider()
            self.finish(nil)
        }
    }

    private func packed(_ fragments: [String], values: [String: String]) -> String? {
        var bytes = fragments.count - 1
        var output: [String] = []
        for fragment in fragments {
            guard let text = values[fragment] else { return nil }
            bytes += text.utf8.count
            guard bytes <= byteLimit else { return nil }
            output.append(text)
        }
        return output.joined(separator: "\u{1f}")
    }

    private func finish(_ output: String?) {
        let ticket = active?.ticket
        active = nil
        watchdog?.cancel()
        watchdog = nil
        worker = nil
        if let ticket { reply(ticket, output) }
    }

    func stop() {
        stopped = true
        active = nil
        worker?.cancel()
        watchdog?.cancel()
        worker = nil
        watchdog = nil
        cancelProvider()
        cache.removeAllObjects()
    }
}

/// Uses only previously downloaded language models. Preparing a game model is
/// a user action in Game Settings. Gameplay never presents a download prompt.
@MainActor
private final class AppleDialogueTranslator {
    private let source: Locale.Language
    private let target = Locale.Language(identifier: "de")
    private var session: TranslationSession?
    private var preparation: Task<Bool, Never>?

    init(source: String) {
        self.source = Locale.Language(identifier: source)
        prepare()
    }

    private func prepare() {
        let source = source
        let target = target
        preparation = Task { [weak self] in
            guard await LanguageAvailability().status(from: source, to: target) == .installed,
                !Task.isCancelled, let self
            else { return false }
            let session = TranslationSession(installedSource: source, target: target)
            self.session = session
            do {
                try await session.prepareTranslation()
                return !Task.isCancelled
            } catch {
                return false
            }
        }
    }

    func translate(_ texts: [String]) async throws -> [String] {
        if preparation == nil { prepare() }
        guard await preparation?.value == true, !Task.isCancelled, let session else { return [] }
        let requests = texts.map { TranslationSession.Request(sourceText: $0) }
        // translations(from:) returns one response per request in the same order.
        let responses = try await session.translations(from: requests)
        return responses.map(\.targetText)
    }

    func reset() {
        preparation?.cancel()
        preparation = nil
        session?.cancel()
        session = nil
    }
}
