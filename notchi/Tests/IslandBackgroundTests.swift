import AppKit
import XCTest
import SwiftUI
@testable import notchi

final class IslandBackgroundTests: XCTestCase {
    func testMissingAndUnknownPreferencesFallBackToGrassland() {
        let name = "IslandBackgroundTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        XCTAssertEqual(AppSettings.islandBackground(in: defaults), .grassland)
        defaults.set("removed-background", forKey: AppSettings.islandBackgroundKey)
        XCTAssertEqual(AppSettings.islandBackground(in: defaults), .grassland)
    }

    func testSelectionSurvivesDefaultsReloadAndVisibilityChanges() {
        let name = "IslandBackgroundTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        for background in IslandBackground.allCases {
            defaults.set(background.rawValue, forKey: AppSettings.islandBackgroundKey)
            defaults.set(false, forKey: AppSettings.showGrassIslandKey)
            XCTAssertEqual(AppSettings.islandBackground(in: UserDefaults(suiteName: name)!), background)
            defaults.set(true, forKey: AppSettings.showGrassIslandKey)
            XCTAssertEqual(AppSettings.islandBackground(in: defaults), background)
        }
    }

    func testEveryBackgroundHasABundledImageWithExpectedDimensions() {
        for background in IslandBackground.allCases {
            let image = NSImage(named: background.assetName)
            XCTAssertNotNil(image, "Missing asset for \(background)")
            let expectedSize = background == .grassland
                ? NSSize(width: 512, height: 512)
                : NSSize(width: 16, height: 16)
            XCTAssertEqual(image?.size, expectedSize)
        }
    }
    func testGroundCraterAssetContainsTheFourStitchedTiles() {
        XCTAssertEqual(NSImage(named: "IslandCrater")?.size, NSSize(width: 32, height: 32))
    }

    func testGroundAndCratersFadeWithUniformOpacity() throws {
        let renderer = ImageRenderer(content:
            IslandBackgroundView(background: .ground)
                .frame(width: 512, height: 160)
                .opacity(0.5)
        )
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        // A separately faded crater over faded ground produces 0.75 alpha instead of 0.5.
        for (x, y) in [(10, 10), (128, 64), (384, 104)] {
            let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y))
            XCTAssertEqual(color.alphaComponent, 0.5, accuracy: 0.01, "Unexpected opacity at \(x), \(y)")
        }
    }

    func testWaterAnimationAdvancesInSheetOrderAndLoops() {
        for frame in 0..<WaterAnimation.frameCount {
            let date = Date(timeIntervalSinceReferenceDate: Double(frame) / 4)
            XCTAssertEqual(WaterAnimation.frameIndex(at: date), frame)
            let image = NSImage(named: WaterAnimation.assetName(frame: frame))
            XCTAssertEqual(image?.size, NSSize(width: 16, height: 16))
        }
        XCTAssertEqual(WaterAnimation.frameIndex(at: Date(timeIntervalSinceReferenceDate: 0.249)), 0)
        XCTAssertEqual(WaterAnimation.frameIndex(at: Date(timeIntervalSinceReferenceDate: 2)), 0)
        XCTAssertEqual(WaterAnimation.frameIndex(at: Date(timeIntervalSinceReferenceDate: -0.25)), 7)
    }

    func testReduceMotionKeepsWaterOnTheFirstFrame() {
        for time in [0.0, 0.125, 0.75, 1.875] {
            XCTAssertEqual(
                WaterAnimation.frameIndex(at: Date(timeIntervalSinceReferenceDate: time), reduceMotion: true),
                0
            )
        }
    }
}
