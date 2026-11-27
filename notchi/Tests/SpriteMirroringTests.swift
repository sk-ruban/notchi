import XCTest
@testable import notchi

@MainActor
final class SpriteMirroringTests: XCTestCase {
    private static let compactingSheetName = "claude_compacting_neutral"
    // FNV-1a hashes of "<seed>|claude_compacting_neutral": even for this seed, so it mirrors.
    private static let mirroredSeed = "session-b"
    // Odd hash, so it doesn't mirror.
    private static let unmirroredSeed = "session-a"
    private static let anyDate = Date(timeIntervalSinceReferenceDate: 0)

    private let compacting = NotchiState(task: .compacting)

    func testMirrorKeyJoinsSeedAndSpriteSheetName() {
        XCTAssertEqual(
            SpriteMirroring.mirrorKey(seed: Self.unmirroredSeed, state: compacting),
            "session-a|claude_compacting_neutral"
        )
    }

    func testCompactingSpriteRendersMirroredAfterSeedingWithAnEvenHashKey() {
        var mirroring = SpriteMirroring()
        mirroring.update(seed: Self.mirroredSeed, state: compacting)

        XCTAssertEqual(
            mirroring.spriteSheetPresentation(state: compacting, seed: Self.mirroredSeed, at: Self.anyDate),
            SpriteSheetPresentation(spriteSheetName: Self.compactingSheetName, renderMirrored: true)
        )
    }

    func testCompactingSpriteRendersUnmirroredAfterReseedingForAnOddHashKey() {
        var mirroring = SpriteMirroring()
        mirroring.update(seed: Self.mirroredSeed, state: compacting)
        mirroring.update(seed: Self.unmirroredSeed, state: compacting)

        XCTAssertEqual(
            mirroring.spriteSheetPresentation(state: compacting, seed: Self.unmirroredSeed, at: Self.anyDate),
            SpriteSheetPresentation(spriteSheetName: Self.compactingSheetName, renderMirrored: false)
        )
    }
}
