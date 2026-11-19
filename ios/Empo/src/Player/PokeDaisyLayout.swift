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

    /// The RGSS thread can park before publishing its rotated game rect. Recreate
    /// the landscape placement from the profile and use the exact engine rect once
    /// it belongs to this canvas. The image contains only the game pixels.
    func drawerSnapshotRect(
        imageSize: CGSize, publishedViewport: CGRect, placement: ScreenPlacement?
    ) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let aspect = imageSize.width / imageSize.height
        let region = placement.flatMap { canvas.region(for: $0, aspect: aspect) }
        let bounds = region.map { canvas.rect(for: canvas.clampedToSafeArea($0)) } ?? canvas.safeRect
        guard bounds.width > 0, bounds.height > 0 else { return .zero }

        // The engine centers both a letterboxed picture and a stretched picture in its bounds.
        if !publishedViewport.isEmpty, abs(publishedViewport.midX - bounds.midX) <= 1,
            abs(publishedViewport.midY - bounds.midY) <= 1,
            abs(publishedViewport.width - bounds.width) <= 1
                || abs(publishedViewport.height - bounds.height) <= 1
        {
            return publishedViewport
        }
        // A previous viewport whose proportions differ from the framebuffer used stretch-to-fill.
        if !publishedViewport.isEmpty, abs(publishedViewport.width - publishedViewport.height * aspect) > 1 {
            return bounds
        }
        let fit = GameAspect.fit(width: bounds.width, height: bounds.height, aspect: aspect)
        return CGRect(
            x: bounds.midX - fit.width / 2, y: bounds.midY - fit.height / 2, width: fit.width,
            height: fit.height)
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
