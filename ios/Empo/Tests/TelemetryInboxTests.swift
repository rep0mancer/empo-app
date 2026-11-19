// SPDX-License-Identifier: GPL-3.0-only

import XCTest

@testable import Empo

final class TelemetryInboxTests: XCTestCase {
    func testCopiesTheBytesAndQueuesOnlyTheLatestUpdate() {
        let inbox = TelemetryInbox()
        inbox.reset(to: 1)
        var byte: UInt8 = 12
        XCTAssertTrue(inbox.offer(&byte, count: 1, generation: 1))
        byte = 25
        XCTAssertFalse(inbox.offer(&byte, count: 1, generation: 1))
        byte = 42
        XCTAssertEqual(inbox.take(generation: 1), Data([25]))
        XCTAssertNil(inbox.take(generation: 1))
        XCTAssertTrue(inbox.offer(&byte, count: 1, generation: 1))
    }

    func testAQueuedDeliveryCannotConsumeTheNextSessionsValue() {
        let inbox = TelemetryInbox()
        var byte: UInt8 = 5
        inbox.reset(to: 1)
        XCTAssertTrue(inbox.offer(&byte, count: 1, generation: 1))
        inbox.reset(to: 2)
        XCTAssertFalse(inbox.offer(&byte, count: 1, generation: 1))
        XCTAssertTrue(inbox.offer(&byte, count: 1, generation: 2))
        XCTAssertNil(inbox.take(generation: 1))
        XCTAssertEqual(inbox.take(generation: 2), Data([5]))
        inbox.reset()
        XCTAssertFalse(inbox.offer(&byte, count: 1, generation: 2))
    }

    func testOversizeAndEmptyCallbacksNeverReadTheBuffer() {
        let inbox = TelemetryInbox()
        var byte: UInt8 = 5
        inbox.reset(to: 1)
        XCTAssertFalse(inbox.offer(nil, count: 4, generation: 1))
        XCTAssertFalse(inbox.offer(&byte, count: 0, generation: 1))
        XCTAssertFalse(inbox.offer(&byte, count: 65537, generation: 1))
        XCTAssertNil(inbox.take(generation: 1))
    }
}
