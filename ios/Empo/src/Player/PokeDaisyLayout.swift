// SPDX-License-Identifier: GPL-3.0-only

import GameProbe
import SwiftUI

/// Geometry is in the same window coordinate space as the engine viewport
/// and ChromeHitRegions. A dock never changes the stored controller profile.
struct PokeDaisyLayout {
    let canvas: ScreenCanvas
    let touchControlsVisible: Bool

    var panel: CGRect {
        let size = canvas.size
        if canvas.isPortrait {
            let split = canvas.safeRect.midY.rounded()
            return CGRect(x: 0, y: split, width: size.width, height: size.height - split)
        }
        let usableWidth = canvas.safeRect.width
        let contentWidth = min(usableWidth * 0.68, max(300, min(416, usableWidth * 0.43)))
        let width = contentWidth + canvas.safeArea.trailing
        return CGRect(x: size.width - width, y: 0, width: width, height: size.height)
    }

    /// Reserve space for touch controls below the picture when they are in use.
    /// A narrow window can still put the pads partly over the game.
    var controlsBandHeight: CGFloat {
        guard canvas.isPortrait, touchControlsVisible else { return 0 }
        return min(
            ControlsZone.minControlsZoneHeight + ControlsZone.padding * 2,
            max(0, panel.minY - canvas.safeRect.minY) * 0.37)
    }

    var portraitViewport: ScreenRegion? {
        guard canvas.isPortrait else { return nil }
        var rect = canvas.safeRect
        rect.size.height = max(1, panel.minY - rect.minY - controlsBandHeight)
        return canvas.region(for: rect)
    }
}
