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
                "https://github.com/octocat/library.git"
            )
            XCTAssertNil(GitSyncCoordinator.normalizedRemote("not a repository"))
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
                GitCommandFailure(message: "Connect the GitHub App before synchronizing.")
            ))
            XCTAssertFalse(GitSyncCoordinator.isRetryableSyncError(
                GitCommandFailure(message: "Could not rebase onto origin/main. Resolve the conflict.")
            ))
        }
    }

    func testSynchronizationPhaseMessagesDescribeCurrentOperation() {
        XCTAssertEqual(GitSynchronizationPhase.checkingLocalChanges.message, "Checking for local changes...")
        XCTAssertEqual(GitSynchronizationPhase.committingLocalChanges.message, "Committing local changes...")
        XCTAssertEqual(GitSynchronizationPhase.fetchingRemoteChanges.message, "Fetching changes from GitHub...")
        XCTAssertEqual(GitSynchronizationPhase.rebasingRemoteChanges.message, "Rebasing onto remote changes...")
        XCTAssertEqual(GitSynchronizationPhase.pushingLocalChanges.message, "Pushing local changes to GitHub...")
    }

    func testConnectRemoteChecksExistingRepositoryBeforeSavingOrigin() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-library-connect-remote-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let remote = "https://github.com/octocat/shared-library.git"
        let runner = ScriptedCommandRunner(responses: [
            key("git", "--version"): [
                .success("git version 2.50"),
                .success("git version 2.50"),
                .success("git version 2.50")
            ],
            key("git", "rev-parse", "--is-inside-work-tree"): [
                .success("true"),
                .success("true"),
                .success("true")
            ],
            key("git", "remote", "get-url", "origin"): [
                .failure(),
                .failure(),
                .success(remote)
            ],
            key("git", "branch", "--show-current"): [.success("main"), .success("main")],
            key("git", "ls-remote", remote): [.success()],
            key("git", "remote", "add", "origin", remote): [.success()]
        ])
        let engine = testEngine(runner: runner)

        let status = try await engine.connectRemote(remote, workspaceURL: workspace)

        XCTAssertEqual(status.remoteURL, remote)
        let calls = await runner.recordedArguments()
        XCTAssertLessThan(
            try XCTUnwrap(calls.firstIndex(of: ["git", "ls-remote", remote])),
            try XCTUnwrap(calls.firstIndex(of: ["git", "remote", "add", "origin", remote]))
        )
    }

    func testSynchronizationRebasesAndPushesWhenBranchesDiverged() async throws {
        let phases = SynchronizationPhaseRecorder()
        let runner = ScriptedCommandRunner(responses: [
            key("git", "--version"): [.success("git version 2.50")],
            key("git", "rev-parse", "--is-inside-work-tree"): [.success("true")],
            key("git", "remote", "get-url", "origin"): [.success("https://github.com/example/library.git")],
            key("git", "branch", "--show-current"): [.success("main"), .success("main")],
            key("git", "rev-parse", "-q", "--verify", "REBASE_HEAD"): [.failure()],
            key("git", "add", "--all"): [.success()],
            key("git", "diff", "--cached", "--quiet"): [.failure(exitCode: 1)],
            key("git", "commit", "-m", "Shared Library sync: capture completed"): [.success()],
            key("git", "fetch", "origin"): [.success()],
            key("git", "show-ref", "--verify", "--quiet", "refs/remotes/origin/main"): [.success()],
            key("git", "rev-list", "--left-right", "--count", "HEAD...origin/main"): [
                .success("1\t1"),
                .success("1\t0")
            ],
            key("git", "rebase", "origin/main"): [.success()],
            key("git", "push", "--set-upstream", "origin", "main"): [.success()]
        ])
        let engine = testEngine(runner: runner)

        let result = try await engine.synchronize(
            workspaceURL: URL(fileURLWithPath: "/tmp/shared-library-sync-test", isDirectory: true),
            reason: "capture completed",
            onProgress: { phase in
                await phases.record(phase)
            }
        )

        XCTAssertTrue(result.committedChanges)
        XCTAssertTrue(result.remoteConfigured)
        XCTAssertTrue(result.integratedRemoteChanges)
        XCTAssertTrue(result.pushedChanges)
        XCTAssertEqual(result.summary, "Remote changes applied and local changes pushed.")
        let recordedPhases = await phases.values()
        XCTAssertEqual(
            recordedPhases,
            [
                .checkingLocalChanges,
                .committingLocalChanges,
                .fetchingRemoteChanges,
                .rebasingRemoteChanges,
                .pushingLocalChanges
            ]
        )
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

    func testSynchronizationSkipsRebaseAndPushWhenEverythingIsUpToDate() async throws {
        let phases = SynchronizationPhaseRecorder()
        let runner = ScriptedCommandRunner(responses: [
            key("git", "--version"): [.success("git version 2.50")],
            key("git", "rev-parse", "--is-inside-work-tree"): [.success("true")],
            key("git", "remote", "get-url", "origin"): [.success("https://github.com/example/library.git")],
            key("git", "branch", "--show-current"): [.success("main"), .success("main")],
            key("git", "rev-parse", "-q", "--verify", "REBASE_HEAD"): [.failure()],
            key("git", "add", "--all"): [.success()],
            key("git", "diff", "--cached", "--quiet"): [.success()],
            key("git", "fetch", "origin"): [.success()],
            key("git", "show-ref", "--verify", "--quiet", "refs/remotes/origin/main"): [.success()],
            key("git", "rev-list", "--left-right", "--count", "HEAD...origin/main"): [.success("0\t0")]
        ])
        let engine = testEngine(runner: runner)

        let result = try await engine.synchronize(
            workspaceURL: URL(fileURLWithPath: "/tmp/shared-library-current-test", isDirectory: true),
            reason: "periodic background sync",
            onProgress: { phase in
                await phases.record(phase)
            }
        )

        XCTAssertFalse(result.committedChanges)
        XCTAssertTrue(result.remoteConfigured)
        XCTAssertFalse(result.integratedRemoteChanges)
        XCTAssertFalse(result.pushedChanges)
        XCTAssertEqual(result.summary, "Everything is up to date.")
        let recordedPhases = await phases.values()
        XCTAssertEqual(recordedPhases, [.checkingLocalChanges, .fetchingRemoteChanges])
        let calls = await runner.recordedArguments()
        XCTAssertFalse(calls.contains(["git", "rebase", "origin/main"]))
        XCTAssertFalse(calls.contains(["git", "push", "--set-upstream", "origin", "main"]))
    }

    func testSynchronizationRebasesRemoteChangesWithoutUnnecessaryPush() async throws {
        let runner = ScriptedCommandRunner(responses: [
            key("git", "--version"): [.success("git version 2.50")],
            key("git", "rev-parse", "--is-inside-work-tree"): [.success("true")],
            key("git", "remote", "get-url", "origin"): [.success("https://github.com/example/library.git")],
            key("git", "branch", "--show-current"): [.success("main"), .success("main")],
            key("git", "rev-parse", "-q", "--verify", "REBASE_HEAD"): [.failure()],
            key("git", "add", "--all"): [.success()],
            key("git", "diff", "--cached", "--quiet"): [.success()],
            key("git", "fetch", "origin"): [.success()],
            key("git", "show-ref", "--verify", "--quiet", "refs/remotes/origin/main"): [.success()],
            key("git", "rev-list", "--left-right", "--count", "HEAD...origin/main"): [
                .success("0\t2"),
                .success("0\t0")
            ],
            key("git", "rebase", "origin/main"): [.success()]
        ])
        let engine = testEngine(runner: runner)

        let result = try await engine.synchronize(
            workspaceURL: URL(fileURLWithPath: "/tmp/shared-library-remote-test", isDirectory: true),
            reason: "periodic background sync"
        )

        XCTAssertTrue(result.integratedRemoteChanges)
        XCTAssertFalse(result.pushedChanges)
        XCTAssertEqual(result.summary, "Remote changes applied.")
        let calls = await runner.recordedArguments()
        XCTAssertTrue(calls.contains(["git", "rebase", "origin/main"]))
        XCTAssertFalse(calls.contains(["git", "push", "--set-upstream", "origin", "main"]))
    }

    func testSynchronizationPushesLocalChangesWithoutUnnecessaryRebase() async throws {
        let runner = ScriptedCommandRunner(responses: [
            key("git", "--version"): [.success("git version 2.50")],
            key("git", "rev-parse", "--is-inside-work-tree"): [.success("true")],
            key("git", "remote", "get-url", "origin"): [.success("https://github.com/example/library.git")],
            key("git", "branch", "--show-current"): [.success("main"), .success("main")],
            key("git", "rev-parse", "-q", "--verify", "REBASE_HEAD"): [.failure()],
            key("git", "add", "--all"): [.success()],
            key("git", "diff", "--cached", "--quiet"): [.failure(exitCode: 1)],
            key("git", "commit", "-m", "Shared Library sync: document edited"): [.success()],
            key("git", "fetch", "origin"): [.success()],
            key("git", "show-ref", "--verify", "--quiet", "refs/remotes/origin/main"): [.success()],
            key("git", "rev-list", "--left-right", "--count", "HEAD...origin/main"): [.success("1\t0")],
            key("git", "push", "--set-upstream", "origin", "main"): [.success()]
        ])
        let engine = testEngine(runner: runner)

        let result = try await engine.synchronize(
            workspaceURL: URL(fileURLWithPath: "/tmp/shared-library-local-ahead-test", isDirectory: true),
            reason: "document edited"
        )

        XCTAssertTrue(result.committedChanges)
        XCTAssertFalse(result.integratedRemoteChanges)
        XCTAssertTrue(result.pushedChanges)
        XCTAssertEqual(result.summary, "Local changes pushed.")
        let calls = await runner.recordedArguments()
        XCTAssertFalse(calls.contains(["git", "rebase", "origin/main"]))
        XCTAssertTrue(calls.contains(["git", "push", "--set-upstream", "origin", "main"]))
    }

    func testSynchronizationWithoutRemoteStillCommitsLocally() async throws {
        let runner = ScriptedCommandRunner(responses: [
            key("git", "--version"): [.success("git version 2.50")],
            key("git", "rev-parse", "--is-inside-work-tree"): [.success("true")],
            key("git", "remote", "get-url", "origin"): [.failure()],
            key("git", "branch", "--show-current"): [.success("main")],
            key("git", "rev-parse", "-q", "--verify", "REBASE_HEAD"): [.failure()],
            key("git", "add", "--all"): [.success()],
            key("git", "diff", "--cached", "--quiet"): [.failure(exitCode: 1)],
            key("git", "commit", "-m", "Shared Library sync: manual sync"): [.success()]
        ])
        let engine = testEngine(runner: runner)

        let result = try await engine.synchronize(
            workspaceURL: URL(fileURLWithPath: "/tmp/shared-library-local-test", isDirectory: true),
            reason: "manual sync"
        )

        XCTAssertTrue(result.committedChanges)
        XCTAssertFalse(result.remoteConfigured)
        XCTAssertFalse(result.integratedRemoteChanges)
        XCTAssertFalse(result.pushedChanges)
        XCTAssertTrue(result.summary.contains("Connect a GitHub repository"))
        let calls = await runner.recordedArguments()
        XCTAssertFalse(calls.contains(["git", "fetch", "origin"]))
    }
}

private actor SynchronizationPhaseRecorder {
    private var recordedValues: [GitSynchronizationPhase] = []

    func record(_ value: GitSynchronizationPhase) {
        recordedValues.append(value)
    }

    func values() -> [GitSynchronizationPhase] {
        recordedValues
    }
}

private actor ScriptedCommandRunner: CommandRunning {
    private var responses: [String: [CommandResult]]
    private var calls: [[String]] = []

    init(responses: [String: [CommandResult]]) {
        self.responses = responses
    }

    func run(executable: String, arguments: [String], workingDirectory: URL?) async -> CommandResult {
        respond(to: arguments)
    }

    func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        additionalEnvironment: [String: String]
    ) async -> CommandResult {
        let normalized: [String]
        if arguments.count >= 6,
           arguments[0] == "git",
           arguments[1] == "-c",
           arguments[3] == "-c" {
            normalized = ["git"] + Array(arguments.dropFirst(5))
        } else {
            normalized = arguments
        }
        return respond(to: normalized)
    }

    private func respond(to arguments: [String]) -> CommandResult {
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

private actor TestGitHubCredentials: GitHubCredentialProviding {
    func configuredClientID() -> String? { "Iv1.shared-library-tests" }

    func validAccessToken(forceRefresh: Bool) -> String? {
        "ghu_shared_library_test"
    }
}

private func testEngine(runner: ScriptedCommandRunner) -> GitSyncEngine {
    GitSyncEngine(
        runner: runner,
        credentials: TestGitHubCredentials()
    )
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
