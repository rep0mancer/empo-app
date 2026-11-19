// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation
import GameProbe
import Observation
import UIKit

@MainActor @Observable
class EngineState {
    static let shared = EngineState()

    var gameRect: CGRect = .zero

    var pauseHolds = SessionPauseHolds()

    private init() {}
}
