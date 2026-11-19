// SPDX-License-Identifier: GPL-3.0-only

import XCTest

@testable import Empo

@MainActor
final class DialogueTranslationServiceTests: XCTestCase {
    func testTranslatesDistinctSegmentsOnceAndPreservesChoiceOrderAndBlanks() async {
        let translated = expectation(description: "First batch translated")
        var batches: [[String]] = []
        var replies: [UInt64: String] = [:]
        let service = DialogueTranslationService(
            byteLimit: 16_384,
            translate: { texts in
                batches.append(texts)
                return ["Ja", "Nein"]
            },
            reply: { id, value in
                replies[id] = value
                if id == 1 { translated.fulfill() }
            })
        service.receive(1, input: "Sí\u{1f}No\u{1f}Sí\u{1f} ")
        await fulfillment(of: [translated], timeout: 2)
        service.receive(2, input: "No\u{1f}Sí")
        XCTAssertEqual(batches, [["Sí", "No"]])
        XCTAssertEqual(replies[1], "Ja\u{1f}Nein\u{1f}Ja\u{1f} ")
        XCTAssertEqual(replies[2], "Nein\u{1f}Ja")
    }

    func testOutstandingColdJobCanServeNewTicketWithoutServingExpiredOne() async {
        let started = expectation(description: "Translator started")
        let finished = expectation(description: "Latest ticket completed")
        var gate: CheckedContinuation<[String], Never>?
        var originalUsed: [UInt64] = []
        let service = DialogueTranslationService(
            byteLimit: 16_384,
            translate: { _ in
                await withCheckedContinuation { continuation in
                    gate = continuation
                    started.fulfill()
                }
            },
            reply: { ticket, result in
                if let result {
                    XCTAssertEqual(ticket, 3)
                    XCTAssertEqual(result, "Guten Morgen!")
                    finished.fulfill()
                } else {
                    originalUsed.append(ticket)
                }
            })
        service.receive(1, input: "Good morning!")
        await fulfillment(of: [started], timeout: 2)
        service.receive(2, input: "Different line")
        service.receive(3, input: "Good morning!")
        gate?.resume(returning: ["Guten Morgen!"])
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(originalUsed, [2, 1])
    }

    func testProviderErrorsInvalidResultsAndOversizeFallBack() async {
        struct Failure: Error {}
        let inputs = ["throws", "split", "long", "empty", "ninebytes", "a\0b"]
        let fallbacks = inputs.indices.map { expectation(description: "Fallback for input \($0)") }
        var count = 0
        let service = DialogueTranslationService(
            byteLimit: 8,
            translate: { input in
                count += 1
                switch input.first {
                case "throws": throw Failure()
                case "split": return ["x\u{1f}y"]
                case "long": return ["länger als acht Bytes"]
                default: return []
                }
            },
            reply: { ticket, value in
                XCTAssertNil(value)
                fallbacks[Int(ticket)].fulfill()
            })
        for (index, value) in inputs.enumerated() {
            service.receive(UInt64(index), input: value)
            await fulfillment(of: [fallbacks[index]], timeout: 2)
        }
        XCTAssertEqual(count, 4)
    }

    func testTimeoutAndTeardownDiscardDelayedProviderResponses() async {
        for stop in [false, true] {
            let started = expectation(description: "Provider is working")
            let expired = expectation(description: "Fallback on watchdog timeout")
            expired.isInverted = stop
            var replies: [UInt64] = []
            var cancellations = 0
            var gate: CheckedContinuation<[String], Never>?
            let service = DialogueTranslationService(
                byteLimit: 16_384, providerTimeout: .milliseconds(50),
                translate: { _ in
                    await withCheckedContinuation { continuation in
                        gate = continuation
                        started.fulfill()
                    }
                }, cancelProvider: { cancellations += 1 },
                reply: { ticket, value in
                    XCTAssertNil(value)
                    replies.append(ticket)
                    expired.fulfill()
                })
            service.receive(11, input: "Original")
            await fulfillment(of: [started], timeout: 2)
            if stop { service.stop() }
            await fulfillment(of: [expired], timeout: stop ? 0.075 : 2)
            gate?.resume(returning: ["Verspätet"])
            await Task.yield()
            XCTAssertEqual(cancellations, 1)
            XCTAssertEqual(replies, stop ? [] : [11])
        }
    }
}
