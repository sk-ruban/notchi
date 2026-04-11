import Sparkle
import XCTest
@testable import notchi

@MainActor
final class UpdateManagerTests: XCTestCase {
    private let manager = UpdateManager.shared

    override func setUp() {
        super.setUp()
        manager.state = .idle
        manager.hasPendingUpdate = false
    }

    override func tearDown() {
        manager.state = .idle
        manager.hasPendingUpdate = false
        super.tearDown()
    }

    func testNoUpdateAbortErrorIsIgnored() {
        let error = NSError(domain: SUSparkleErrorDomain, code: UpdateManager.noUpdateErrorCode)

        XCTAssertTrue(UpdateManager.shouldIgnoreAbortError(error))
    }

    func testUpdateErrorUsesShortInlineLabel() {
        manager.updateError()

        guard case .error(let failure) = manager.state else {
            return XCTFail("Expected error state")
        }

        XCTAssertEqual(failure.label, "Try again")
    }

    func testBeginCheckingReplacesPreviousFailureState() {
        manager.updateError()

        manager.beginChecking()

        XCTAssertEqual(manager.state, .checking)
    }

    func testClearTransientStatusClearsUpToDateAndErrorStates() {
        manager.noUpdateFound()
        manager.clearTransientStatus()
        XCTAssertEqual(manager.state, .idle)

        manager.updateError()
        manager.clearTransientStatus()
        XCTAssertEqual(manager.state, .idle)
    }
}
