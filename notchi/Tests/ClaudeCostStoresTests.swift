import Foundation
import XCTest
@testable import notchi

@MainActor
final class ClaudeCostStoresTests: XCTestCase {
    private static let sharedFolder = URL(fileURLWithPath: "/Users/someone/.claude")
    private static let work = account(".claude", name: "Work", isDefault: true)
    private static let personal = account(".claude-personal", name: "Personal")
    private static let team = account(".claude-team", name: "Team")

    private static func account(_ folder: String, name: String, isDefault: Bool = false) -> ClaudeAccount {
        let directory = URL(fileURLWithPath: "/Users/someone/\(folder)")
        return ClaudeAccount(
            key: directory.path, directory: directory, isDefault: isDefault,
            name: name, color: .orange, isNotchiEnabled: true
        )
    }

    private var sharedStore: CostHistoryStore!
    private var createdKeys: [String] = []

    private func makeStores() -> ClaudeCostStores {
        sharedStore = CostHistoryStore { _ in [:] }
        return ClaudeCostStores(sharedStore: sharedStore, sharedStoreDirectory: Self.sharedFolder) { [unowned self] account in
            createdKeys.append(account.key)
            return CostHistoryStore { _ in [:] }
        }
    }

    func testAccountInTheSharedFolderUsesTheSharedStore() {
        let stores = makeStores()
        stores.sync(with: [Self.work])

        XCTAssertTrue(stores.store(for: Self.work) === sharedStore)
    }

    // CLAUDE_CONFIG_DIR can make another folder the default; it must read its own spend, not ~/.claude's.
    func testDefaultAccountInAnotherFolderReadsItsOwnFolder() {
        let stores = makeStores()
        let defaultElsewhere = Self.account(".claude-work", name: "Work", isDefault: true)

        stores.sync(with: [defaultElsewhere, Self.work])

        XCTAssertEqual(createdKeys, [defaultElsewhere.key])
    }

    func testSyncCreatesAStorePerAccountOutsideTheSharedFolder() {
        let stores = makeStores()

        stores.sync(with: [Self.work, Self.personal, Self.team])

        XCTAssertEqual(Set(createdKeys), [Self.personal.key, Self.team.key])
    }

    func testSyncStopsTrackingAccountsSwitchedOff() {
        let stores = makeStores()
        stores.sync(with: [Self.work, Self.personal, Self.team])

        stores.sync(with: [Self.work, Self.personal])

        XCTAssertEqual(stores.trackedAccountKeys, [Self.personal.key])
    }

    func testSwitchedOffAccountHasNoStore() {
        let stores = makeStores()
        stores.sync(with: [Self.work, Self.personal])

        stores.sync(with: [Self.work])

        XCTAssertNil(stores.store(for: Self.personal))
    }

    func testSwitchingAnAccountBackOnReusesItsStore() {
        let stores = makeStores()
        stores.sync(with: [Self.work, Self.personal])
        stores.sync(with: [Self.work])

        stores.sync(with: [Self.work, Self.personal])

        XCTAssertEqual(createdKeys, [Self.personal.key])
    }
}
