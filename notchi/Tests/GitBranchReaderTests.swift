import XCTest
@testable import notchi

final class GitBranchReaderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitBranchReaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testReadsBranchNameFromSymbolicHead() throws {
        try writeGitDir(at: root, head: "ref: refs/heads/main\n")

        XCTAssertEqual(GitBranchReader.branch(forRepositoryAt: root.path), "main")
    }

    func testPreservesSlashesInBranchName() throws {
        try writeGitDir(at: root, head: "ref: refs/heads/fix/permission-mode-badge-colors\n")

        XCTAssertEqual(GitBranchReader.branch(forRepositoryAt: root.path), "fix/permission-mode-badge-colors")
    }

    func testDetachedHeadReturnsShortSha() throws {
        try writeGitDir(at: root, head: "f71b1b8c2a9d4e6f0b1c3d5e7f9a0b2c4d6e8f0a\n")

        XCTAssertEqual(GitBranchReader.branch(forRepositoryAt: root.path), "f71b1b8")
    }

    func testResolvesRepositoryFromSubdirectory() throws {
        try writeGitDir(at: root, head: "ref: refs/heads/main\n")
        let nested = root.appendingPathComponent("notchi/notchi/Views")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        XCTAssertEqual(GitBranchReader.branch(forRepositoryAt: nested.path), "main")
    }

    func testResolvesWorktreeGitdirFile() throws {
        let worktreeGitDir = root.appendingPathComponent("main-repo/.git/worktrees/feature")
        try FileManager.default.createDirectory(at: worktreeGitDir, withIntermediateDirectories: true)
        try "ref: refs/heads/feat/on-device-emotion-analysis\n"
            .write(to: worktreeGitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)

        let worktree = root.appendingPathComponent("worktrees/feature")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: \(worktreeGitDir.path)\n"
            .write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        XCTAssertEqual(GitBranchReader.branch(forRepositoryAt: worktree.path), "feat/on-device-emotion-analysis")
    }

    func testReturnsNilOutsideRepository() {
        XCTAssertNil(GitBranchReader.branch(forRepositoryAt: root.path))
    }

    func testReturnsNilForRootPath() {
        XCTAssertNil(GitBranchReader.branch(forRepositoryAt: "/"))
    }

    func testReturnsNilForEmptyPath() {
        XCTAssertNil(GitBranchReader.branch(forRepositoryAt: ""))
    }

    private func writeGitDir(at directory: URL, head: String) throws {
        let gitDir = directory.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try head.write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
    }
}
