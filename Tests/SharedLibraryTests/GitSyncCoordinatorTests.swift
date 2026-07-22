import XCTest
@testable import SharedLibrary

final class GitSyncCoordinatorTests: XCTestCase {
    func testRemoteNormalizationAcceptsGitHubSlugAndURLs() async {
        await MainActor.run {
            XCTAssertEqual(
                GitSyncCoordinator.normalizedRemote("octocat/library"),
                "https://github.com/octocat/library.git"
            )
            XCTAssertEqual(
                GitSyncCoordinator.normalizedRemote("git@github.com:octocat/library.git"),
                "git@github.com:octocat/library.git"
            )
            XCTAssertNil(GitSyncCoordinator.normalizedRemote("not a repository"))
            XCTAssertEqual(GitSyncCoordinator.normalizedRepositoryName("library"), "library")
            XCTAssertEqual(GitSyncCoordinator.normalizedRepositoryName("octocat/library"), "octocat/library")
            XCTAssertNil(GitSyncCoordinator.normalizedRepositoryName("octocat/shared library"))
        }
    }

    func testBackgroundRetryClassificationOnlyAcceptsTransientNetworkFailures() async {
        await MainActor.run {
            XCTAssertTrue(GitSyncCoordinator.isRetryableSyncError(
                GitCommandFailure(message: "Could not fetch from origin. Network is unreachable")
            ))
            XCTAssertTrue(GitSyncCoordinator.isRetryableSyncError(
                GitCommandFailure(message: "Could not push main. Connection timed out")
            ))
            XCTAssertFalse(GitSyncCoordinator.isRetryableSyncError(
                GitCommandFailure(message: "GitHub CLI is not authenticated. Run gh auth login.")
            ))
            XCTAssertFalse(GitSyncCoordinator.isRetryableSyncError(
                GitCommandFailure(message: "Could not rebase onto origin/main. Resolve the conflict.")
            ))
        }
    }

    func testCreateRemoteRepositoryCommitsCreatesOriginAndPushes() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-library-create-remote-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let createArguments = [
            "gh", "repo", "create", "octocat/shared-library",
            "--public",
            "--source", workspace.path,
            "--remote", "origin",
            "--push"
        ]
        let runner = ScriptedCommandRunner(responses: [
            key("git", "--version"): [
                .success("git version 2.50"),
                .success("git version 2.50"),
                .success("git version 2.50")
            ],
            key("gh", "--version"): [.success("gh version 2.76"), .success("gh version 2.76")],
            key("gh", "auth", "status", "--hostname", "github.com"): [
                .success("authenticated"),
                .success("authenticated")
            ],
            key("git", "rev-parse", "--is-inside-work-tree"): [
                .success("true"),
                .success("true"),
                .success("true")
            ],
            key("git", "remote", "get-url", "origin"): [
                .failure(),
                .success("https://github.com/octocat/shared-library.git")
            ],
            key("git", "branch", "--show-current"): [.success("main"), .success("main")],
            key("git", "add", "--all"): [.success()],
            key("git", "diff", "--cached", "--quiet"): [.failure(exitCode: 1)],
            key("git", "commit", "-m", "Shared Library sync: initial GitHub repository"): [.success()],
            key("git", "rev-parse", "--verify", "HEAD"): [.success("abc123")],
            key("gh", "auth", "setup-git", "--hostname", "github.com"): [.success()],
            createArguments.joined(separator: "\u{1F}"): [.success("https://github.com/octocat/shared-library")]
        ])
        let engine = GitSyncEngine(runner: runner)

        let status = try await engine.createRemoteRepository(
            name: "octocat/shared-library",
            visibility: .publicRepository,
            workspaceURL: workspace
        )

        XCTAssertEqual(status.remoteURL, "https://github.com/octocat/shared-library.git")
        let calls = await runner.recordedArguments()
        XCTAssertLessThan(
            try XCTUnwrap(calls.firstIndex(of: ["git", "commit", "-m", "Shared Library sync: initial GitHub repository"])),
            try XCTUnwrap(calls.firstIndex(of: createArguments))
        )
    }

    func testCreateRemoteRepositoryMakesEmptyInitialCommitWhenNeeded() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-library-create-empty-remote-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let createArguments = [
            "gh", "repo", "create", "shared-library",
            "--private",
            "--source", workspace.path,
            "--remote", "origin",
            "--push"
        ]
        let runner = ScriptedCommandRunner(responses: [
            key("git", "--version"): [
                .success("git version 2.50"),
                .success("git version 2.50"),
                .success("git version 2.50")
            ],
            key("gh", "--version"): [.success("gh version 2.76"), .success("gh version 2.76")],
            key("gh", "auth", "status", "--hostname", "github.com"): [
                .success("authenticated"),
                .success("authenticated")
            ],
            key("git", "rev-parse", "--is-inside-work-tree"): [
                .success("true"),
                .success("true"),
                .success("true")
            ],
            key("git", "remote", "get-url", "origin"): [
                .failure(),
                .success("https://github.com/octocat/shared-library.git")
            ],
            key("git", "branch", "--show-current"): [.success("main"), .success("main")],
            key("git", "add", "--all"): [.success()],
            key("git", "diff", "--cached", "--quiet"): [.success()],
            key("git", "rev-parse", "--verify", "HEAD"): [.failure()],
            key("git", "commit", "--allow-empty", "-m", "Shared Library sync: initial GitHub repository"): [.success()],
            key("gh", "auth", "setup-git", "--hostname", "github.com"): [.success()],
            createArguments.joined(separator: "\u{1F}"): [.success("https://github.com/octocat/shared-library")]
        ])
        let engine = GitSyncEngine(runner: runner)

        let status = try await engine.createRemoteRepository(
            name: "shared-library",
            visibility: .privateRepository,
            workspaceURL: workspace
        )

        XCTAssertEqual(status.remoteURL, "https://github.com/octocat/shared-library.git")
        let calls = await runner.recordedArguments()
        XCTAssertLessThan(
            try XCTUnwrap(calls.firstIndex(of: ["git", "commit", "--allow-empty", "-m", "Shared Library sync: initial GitHub repository"])),
            try XCTUnwrap(calls.firstIndex(of: createArguments))
        )
    }

    func testSynchronizationCommitsFetchesRebasesAndPushes() async throws {
        let runner = ScriptedCommandRunner(responses: [
            key("git", "--version"): [.success("git version 2.50")],
            key("gh", "--version"): [.success("gh version 2.76")],
            key("gh", "auth", "status", "--hostname", "github.com"): [.success("authenticated")],
            key("git", "rev-parse", "--is-inside-work-tree"): [.success("true")],
            key("git", "remote", "get-url", "origin"): [.success("https://github.com/example/library.git")],
            key("git", "branch", "--show-current"): [.success("main"), .success("main")],
            key("git", "rev-parse", "-q", "--verify", "REBASE_HEAD"): [.failure()],
            key("git", "add", "--all"): [.success()],
            key("git", "diff", "--cached", "--quiet"): [.failure(exitCode: 1)],
            key("git", "commit", "-m", "Shared Library sync: capture completed"): [.success()],
            key("gh", "auth", "setup-git", "--hostname", "github.com"): [.success()],
            key("git", "fetch", "origin"): [.success()],
            key("git", "show-ref", "--verify", "--quiet", "refs/remotes/origin/main"): [.success()],
            key("git", "rebase", "origin/main"): [.success()],
            key("git", "push", "--set-upstream", "origin", "main"): [.success()]
        ])
        let engine = GitSyncEngine(runner: runner)

        let result = try await engine.synchronize(
            workspaceURL: URL(fileURLWithPath: "/tmp/shared-library-sync-test", isDirectory: true),
            reason: "capture completed"
        )

        XCTAssertTrue(result.committedChanges)
        XCTAssertTrue(result.pushedChanges)
        let calls = await runner.recordedArguments()
        XCTAssertLessThan(
            try XCTUnwrap(calls.firstIndex(of: ["git", "commit", "-m", "Shared Library sync: capture completed"])),
            try XCTUnwrap(calls.firstIndex(of: ["git", "fetch", "origin"]))
        )
        XCTAssertLessThan(
            try XCTUnwrap(calls.firstIndex(of: ["git", "fetch", "origin"])),
            try XCTUnwrap(calls.firstIndex(of: ["git", "rebase", "origin/main"]))
        )
        XCTAssertLessThan(
            try XCTUnwrap(calls.firstIndex(of: ["git", "rebase", "origin/main"])),
            try XCTUnwrap(calls.firstIndex(of: ["git", "push", "--set-upstream", "origin", "main"]))
        )
    }

    func testSynchronizationWithoutRemoteStillCommitsLocally() async throws {
        let runner = ScriptedCommandRunner(responses: [
            key("git", "--version"): [.success("git version 2.50")],
            key("gh", "--version"): [.success("gh version 2.76")],
            key("gh", "auth", "status", "--hostname", "github.com"): [.success("authenticated")],
            key("git", "rev-parse", "--is-inside-work-tree"): [.success("true")],
            key("git", "remote", "get-url", "origin"): [.failure()],
            key("git", "branch", "--show-current"): [.success("main")],
            key("git", "rev-parse", "-q", "--verify", "REBASE_HEAD"): [.failure()],
            key("git", "add", "--all"): [.success()],
            key("git", "diff", "--cached", "--quiet"): [.failure(exitCode: 1)],
            key("git", "commit", "-m", "Shared Library sync: manual sync"): [.success()]
        ])
        let engine = GitSyncEngine(runner: runner)

        let result = try await engine.synchronize(
            workspaceURL: URL(fileURLWithPath: "/tmp/shared-library-local-test", isDirectory: true),
            reason: "manual sync"
        )

        XCTAssertTrue(result.committedChanges)
        XCTAssertFalse(result.pushedChanges)
        XCTAssertTrue(result.summary.contains("Connect a GitHub repository"))
        let calls = await runner.recordedArguments()
        XCTAssertFalse(calls.contains(["git", "fetch", "origin"]))
    }
}

private actor ScriptedCommandRunner: CommandRunning {
    private var responses: [String: [CommandResult]]
    private var calls: [[String]] = []

    init(responses: [String: [CommandResult]]) {
        self.responses = responses
    }

    func run(executable: String, arguments: [String], workingDirectory: URL?) async -> CommandResult {
        calls.append(arguments)
        let responseKey = arguments.joined(separator: "\u{1F}")
        guard var queued = responses[responseKey], !queued.isEmpty else {
            return .failure(message: "Unexpected command: \(arguments.joined(separator: " "))")
        }
        let result = queued.removeFirst()
        responses[responseKey] = queued
        return result
    }

    func recordedArguments() -> [[String]] { calls }
}

private func key(_ arguments: String...) -> String {
    arguments.joined(separator: "\u{1F}")
}

private extension CommandResult {
    static func success(_ output: String = "") -> CommandResult {
        CommandResult(exitCode: 0, standardOutput: output, standardError: "")
    }

    static func failure(exitCode: Int32 = 1, message: String = "") -> CommandResult {
        CommandResult(exitCode: exitCode, standardOutput: "", standardError: message)
    }
}
