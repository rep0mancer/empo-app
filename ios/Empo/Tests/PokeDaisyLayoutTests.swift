// SPDX-License-Identifier: GPL-3.0-only

import GameProbe
import SwiftUI
import XCTest

@testable import Empo

@MainActor
final class PokeDaisyLayoutTests: XCTestCase {
    func testDockPinsThePictureAboveTheLiveControlBand() throws {
        let canvas = ScreenCanvas(
            size: CGSize(width: 393, height: 852),
            safeArea: EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0))
        let dock = PokeDaisyLayout(canvas: canvas, touchControlsVisible: true)
        let rect = canvas.rect(for: try XCTUnwrap(dock.portraitViewport))
        XCTAssertEqual(rect.minY, canvas.safeRect.minY, accuracy: 0.01)
        XCTAssertEqual(rect.maxY + dock.controlsBandHeight, dock.panel.minY, accuracy: 0.01)
        XCTAssertEqual(dock.panel.minY, canvas.safeRect.midY.rounded())
        XCTAssertEqual(dock.panel.maxY, canvas.size.height)
        let hiddenControls = PokeDaisyLayout(canvas: canvas, touchControlsVisible: false)
        XCTAssertEqual(
            canvas.rect(for: try XCTUnwrap(hiddenControls.portraitViewport)).maxY,
            dock.panel.minY, accuracy: 0.01)
    }

    func testParkedPortraitFrameMovesToTheLandscapeViewport() {
        let canvas = ScreenCanvas(
            size: CGSize(width: 844, height: 390),
            safeArea: EdgeInsets(top: 0, leading: 47, bottom: 21, trailing: 47))
        let drawer = PokeDaisyLayout(canvas: canvas, touchControlsVisible: true)
        let picture = CGSize(width: 640, height: 480)
        let oldPortraitViewport = CGRect(x: 35, y: 47, width: 320, height: 240)
        XCTAssertEqual(
            drawer.drawerSnapshotRect(
                imageSize: picture, publishedViewport: oldPortraitViewport, placement: nil),
            CGRect(x: 162, y: 0, width: 520, height: 390))
        let customBounds = CGRect(x: 80, y: 40, width: 320, height: 180)
        let placement = ScreenPlacement.region(canvas.region(for: customBounds))
        XCTAssertEqual(
            drawer.drawerSnapshotRect(
                imageSize: picture, publishedViewport: oldPortraitViewport, placement: placement),
            CGRect(x: 120, y: 40, width: 240, height: 180))
        let oldStretchedViewport = CGRect(x: 0, y: 47, width: 390, height: 240)
        XCTAssertEqual(
            drawer.drawerSnapshotRect(
                imageSize: picture, publishedViewport: oldStretchedViewport, placement: placement),
            customBounds)
    }

    func testDrawerLeavesTheGameViewportAloneAndFitsInsideTheWindow() {
        for width: CGFloat in [667, 852, 1194] {
            let canvas = ScreenCanvas(
                size: CGSize(width: width, height: 375),
                safeArea: EdgeInsets(top: 0, leading: 50, bottom: 20, trailing: 50))
            let drawer = PokeDaisyLayout(canvas: canvas, touchControlsVisible: true)
            XCTAssertNil(drawer.portraitViewport)
            XCTAssertEqual(drawer.panel.maxX, canvas.size.width, accuracy: 0.01)
            XCTAssertGreaterThanOrEqual(drawer.panel.width - canvas.safeArea.trailing, 300)
            XCTAssertGreaterThan(drawer.panel.minX, canvas.safeArea.leading)
        }
    }
}
