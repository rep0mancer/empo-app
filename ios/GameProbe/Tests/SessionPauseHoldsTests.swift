// SPDX-License-Identifier: GPL-3.0-only

import XCTest

@testable import GameProbe

final class SessionPauseHoldsTests: XCTestCase {
    func testBackgroundAcrossFirstFrameWaitsUntilCoreCanPause() {
        var holds = SessionPauseHolds()
        XCTAssertEqual(holds.set(.background, active: true), .none)
        XCTAssertFalse(holds.countsPlayTime)
        XCTAssertEqual(holds.didStart(), .pause)
        XCTAssertEqual(holds.set(.background, active: false), .none)
        XCTAssertFalse(holds.countsPlayTime)
        XCTAssertEqual(holds.didPause(), .resume)
        XCTAssertFalse(holds.isRunning)
        XCTAssertEqual(holds.didResume(), .none)
        XCTAssertTrue(holds.countsPlayTime)
    }

    func testReturningBeforeStartupClearsBackgroundWithoutTouchingCore() {
        var holds = SessionPauseHolds()
        XCTAssertEqual(holds.set(.background, active: true), .none)
        XCTAssertEqual(holds.set(.background, active: false), .none)
        XCTAssertTrue(holds.countsPlayTime)
        XCTAssertEqual(holds.didStart(), .none)
        XCTAssertTrue(holds.isRunning)
    }

    func testNewPauseWaitsForResumeAcknowledgement() {
        var holds = SessionPauseHolds()
        _ = holds.didStart()
        _ = holds.set(.overlay, active: true)
        _ = holds.didPause()
        XCTAssertEqual(holds.set(.overlay, active: false), .resume)
        XCTAssertEqual(holds.set(.background, active: true), .none)
        XCTAssertEqual(holds.didPause(), .none)
        XCTAssertEqual(holds.didResume(), .pause)
        XCTAssertFalse(holds.isRunning)
        XCTAssertEqual(holds.didResume(), .none)
        XCTAssertEqual(holds.didPause(), .none)
        XCTAssertTrue(holds.isParked)
    }

    func testMenuBackgroundAndLibraryShareOnePause() {
        var holds = SessionPauseHolds()
        XCTAssertEqual(holds.didStart(), .none)
        XCTAssertEqual(holds.set(.overlay, active: true), .pause)
        XCTAssertEqual(holds.set(.background, active: true), .none)
        XCTAssertEqual(holds.didPause(), .none)
        XCTAssertTrue(holds.isParked)
        XCTAssertEqual(holds.set(.background, active: false), .none)
        XCTAssertEqual(holds.set(.library, active: true), .none)
        XCTAssertEqual(holds.set(.overlay, active: false), .none)
        XCTAssertEqual(holds.set(.library, active: false), .resume)
        XCTAssertFalse(holds.isParked)
    }

    func testDismissBeforeCallbackResumesOnceAtSafePoint() {
        var holds = SessionPauseHolds()
        XCTAssertEqual(holds.didStart(), .none)
        XCTAssertEqual(holds.set(.overlay, active: true), .pause)
        XCTAssertEqual(holds.set(.overlay, active: false), .none)
        XCTAssertEqual(holds.didPause(), .resume)
        XCTAssertEqual(holds.didPause(), .none)
    }

    func testReopeningBeforeAcknowledgementKeepsGameParked() {
        var holds = SessionPauseHolds()
        XCTAssertEqual(holds.didStart(), .none)
        XCTAssertEqual(holds.set(.background, active: true), .pause)
        XCTAssertEqual(holds.set(.background, active: false), .none)
        XCTAssertEqual(holds.set(.overlay, active: true), .none)
        XCTAssertEqual(holds.didPause(), .none)
        XCTAssertTrue(holds.isParked)
        XCTAssertEqual(holds.set(.overlay, active: false), .resume)
    }
}