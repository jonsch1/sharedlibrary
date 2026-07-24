import Foundation
import Combine

struct CommandResult: Equatable, Sendable {
    var exitCode: Int32
    var standardOutput: String
    var standardError: String

    var succeeded: Bool { exitCode == 0 }

    var output: String {
        let values = [standardOutput, standardError]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return values.joined(separator: "\n")
    }
}

protocol CommandRunning: Sendable {
    func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL?
    ) async -> CommandResult

    func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        additionalEnvironment: [String: String]
    ) async -> CommandResult
}

extension CommandRunning {
    func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        additionalEnvironment: [String: String]
    ) async -> CommandResult {
        await run(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory
        )
    }
}

struct ProcessCommandRunner: CommandRunning {
    func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL?
    ) async -> CommandResult {
        await Task.detached(priority: .utility) {
            let process = Process()
            let standardOutput = Pipe()
            let standardError = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = workingDirectory
            process.environment = Self.commandEnvironment()
            process.standardOutput = standardOutput
            process.standardError = standardError

            do {
                try process.run()
                process.waitUntilExit()
                return CommandResult(
                    exitCode: process.terminationStatus,
                    standardOutput: String(
                        data: standardOutput.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8
                    ) ?? "",
                    standardError: String(
                        data: standardError.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8
                    ) ?? ""
                )
            } catch {
                return CommandResult(
                    exitCode: 127,
                    standardOutput: "",
                    standardError: error.localizedDescription
                )
            }
        }.value
    }

    func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        additionalEnvironment: [String: String]
    ) async -> CommandResult {
        await Task.detached(priority: .utility) {
            let process = Process()
            let standardOutput = Pipe()
            let standardError = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = workingDirectory
            process.environment = Self.commandEnvironment().merging(additionalEnvironment) {
                _, new in new
            }
            process.standardOutput = standardOutput
            process.standardError = standardError

            do {
                try process.run()
                process.waitUntilExit()
                return CommandResult(
                    exitCode: process.terminationStatus,
                    standardOutput: String(
                        data: standardOutput.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8
                    ) ?? "",
                    standardError: String(
                        data: standardError.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8
                    ) ?? ""
                )
            } catch {
                return CommandResult(
                    exitCode: 127,
                    standardOutput: "",
                    standardError: error.localizedDescription
                )
            }
        }.value
    }

    private static func commandEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let preferredPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/local/bin",
            "\(home)/.local/bin",
            "/usr/bin",
            "/bin"
        ]
        let existingPaths = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        var seen = Set<String>()
        environment["PATH"] = (preferredPaths + existingPaths)
            .filter { seen.insert($0).inserted }
            .joined(separator: ":")
        return environment
    }
}

struct GitRepositoryStatus: Equatable, Sendable {
    var gitAvailable: Bool
    var githubAppConfigured: Bool
    var githubAuthenticated: Bool
    var isRepository: Bool
    var remoteURL: String?
    var branch: String?

    static let unknown = GitRepositoryStatus(
        gitAvailable: false,
        githubAppConfigured: false,
        githubAuthenticated: false,
        isRepository: false,
        remoteURL: nil,
        branch: nil
    )

    var hasRemote: Bool { remoteURL != nil }
}

struct GitSynchronizationResult: Equatable, Sendable {
    var committedChanges: Bool
    var remoteConfigured: Bool
    var integratedRemoteChanges: Bool
    var pushedChanges: Bool
    var summary: String
}

enum GitSynchronizationPhase: Equatable, Sendable {
    case checkingLocalChanges
    case committingLocalChanges
    case fetchingRemoteChanges
    case rebasingRemoteChanges
    case pushingLocalChanges

    var message: String {
        switch self {
        case .checkingLocalChanges:
            return "Checking for local changes..."
        case .committingLocalChanges:
            return "Committing local changes..."
        case .fetchingRemoteChanges:
            return "Fetching changes from GitHub..."
        case .rebasingRemoteChanges:
            return "Rebasing onto remote changes..."
        case .pushingLocalChanges:
            return "Pushing local changes to GitHub..."
        }
    }
}

struct GitCommandFailure: LocalizedError, Equatable, Sendable {
    var message: String
    var errorDescription: String? { message }
}

actor GitSyncEngine {
    private let runner: any CommandRunning
    private let credentials: any GitHubCredentialProviding
    private let environmentExecutable = "/usr/bin/env"

    init(
        runner: any CommandRunning = ProcessCommandRunner(),
        credentials: any GitHubCredentialProviding = GitHubCredentialVault.shared
    ) {
        self.runner = runner
        self.credentials = credentials
    }

    func inspect(workspaceURL: URL) async -> GitRepositoryStatus {
        let gitAvailable = await command("git", ["--version"], in: nil).succeeded
        let githubAppConfigured = await credentials.configuredClientID() != nil
        let githubAuthenticated = (try? await credentials.validAccessToken(forceRefresh: false)) != nil

        guard gitAvailable else {
            return GitRepositoryStatus(
                gitAvailable: false,
                githubAppConfigured: githubAppConfigured,
                githubAuthenticated: githubAuthenticated,
                isRepository: false,
                remoteURL: nil,
                branch: nil
            )
        }

        let repositoryCheck = await command(
            "git",
            ["rev-parse", "--is-inside-work-tree"],
            in: workspaceURL
        )
        let isRepository = repositoryCheck.succeeded
            && repositoryCheck.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        guard isRepository else {
            return GitRepositoryStatus(
                gitAvailable: true,
                githubAppConfigured: githubAppConfigured,
                githubAuthenticated: githubAuthenticated,
                isRepository: false,
                remoteURL: nil,
                branch: nil
            )
        }

        let remoteResult = await command("git", ["remote", "get-url", "origin"], in: workspaceURL)
        let branchResult = await command("git", ["branch", "--show-current"], in: workspaceURL)
        return GitRepositoryStatus(
            gitAvailable: true,
            githubAppConfigured: githubAppConfigured,
            githubAuthenticated: githubAuthenticated,
            isRepository: true,
            remoteURL: nonemptyOutput(remoteResult),
            branch: nonemptyOutput(branchResult)
        )
    }

    func initializeRepository(workspaceURL: URL) async throws -> GitRepositoryStatus {
        guard await command("git", ["--version"], in: nil).succeeded else {
            throw GitCommandFailure(message: "Git is not installed or is not available on PATH.")
        }

        let repositoryCheck = await command(
            "git",
            ["rev-parse", "--is-inside-work-tree"],
            in: workspaceURL
        )
        if !repositoryCheck.succeeded {
            let initialized = await command("git", ["init", "-b", "main"], in: workspaceURL)
            if !initialized.succeeded {
                try requireSuccess(
                    await command("git", ["init"], in: workspaceURL),
                    operation: "initialize the Git repository"
                )
                _ = await command("git", ["branch", "-M", "main"], in: workspaceURL)
            }
        }

        try ensureWorkspaceGitignore(workspaceURL: workspaceURL)
        return await inspect(workspaceURL: workspaceURL)
    }

    func connectRemote(_ remote: String, workspaceURL: URL) async throws -> GitRepositoryStatus {
        var status = try await initializeRepository(workspaceURL: workspaceURL)
        guard status.githubAuthenticated else {
            throw GitCommandFailure(
                message: "Connect the GitHub App before connecting a repository."
            )
        }
        let accessCheck = try await authenticatedGitCommand(
            ["ls-remote", remote],
            in: workspaceURL
        )
        guard accessCheck.succeeded else {
            let detail = accessCheck.output.isEmpty
                ? "Git exited with status \(accessCheck.exitCode)."
                : accessCheck.output
            throw GitCommandFailure(
                message: """
                Shared Library could not access this repository. Create it on GitHub first, \
                install the Shared Library GitHub App on that repository, then try again. \(detail)
                """
            )
        }
        let existingRemote = await command("git", ["remote", "get-url", "origin"], in: workspaceURL)
        if existingRemote.succeeded {
            try requireSuccess(
                await command("git", ["remote", "set-url", "origin", remote], in: workspaceURL),
                operation: "update the origin remote"
            )
        } else {
            try requireSuccess(
                await command("git", ["remote", "add", "origin", remote], in: workspaceURL),
                operation: "add the origin remote"
            )
        }
        status = await inspect(workspaceURL: workspaceURL)
        return status
    }

    func synchronize(
        workspaceURL: URL,
        reason: String,
        onProgress: @escaping @Sendable (GitSynchronizationPhase) async -> Void = { _ in }
    ) async throws -> GitSynchronizationResult {
        let initialStatus = await inspect(workspaceURL: workspaceURL)
        guard initialStatus.gitAvailable else {
            throw GitCommandFailure(message: "Git is not installed or is not available on PATH.")
        }
        guard initialStatus.isRepository else {
            throw GitCommandFailure(message: "Initialize this workspace as a Git repository before syncing.")
        }

        let rebaseCheck = await command("git", ["rev-parse", "-q", "--verify", "REBASE_HEAD"], in: workspaceURL)
        guard !rebaseCheck.succeeded else {
            throw GitCommandFailure(message: "A Git rebase is already in progress. Resolve or abort it before syncing again.")
        }

        await onProgress(.checkingLocalChanges)
        let committedChanges = try await commitWorkspaceChanges(
            workspaceURL: workspaceURL,
            reason: reason,
            onCommit: {
                await onProgress(.committingLocalChanges)
            }
        )

        guard let remote = initialStatus.remoteURL, !remote.isEmpty else {
            return GitSynchronizationResult(
                committedChanges: committedChanges,
                remoteConfigured: false,
                integratedRemoteChanges: false,
                pushedChanges: false,
                summary: committedChanges
                    ? "Changes committed locally. Connect a GitHub repository to publish them."
                    : "No local changes. Connect a GitHub repository to enable synchronization."
            )
        }
        guard initialStatus.githubAuthenticated else {
            throw GitCommandFailure(message: "Connect the GitHub App before synchronizing.")
        }

        await onProgress(.fetchingRemoteChanges)
        try requireSuccess(
            try await authenticatedGitCommand(["fetch", "origin"], in: workspaceURL),
            operation: "fetch from \(remote)"
        )

        let branchResult = await command("git", ["branch", "--show-current"], in: workspaceURL)
        let branch = nonemptyOutput(branchResult) ?? initialStatus.branch ?? "main"
        let remoteBranch = await command(
            "git",
            ["show-ref", "--verify", "--quiet", "refs/remotes/origin/\(branch)"],
            in: workspaceURL
        )

        var integratedRemoteChanges = false
        var pushedChanges = false
        if remoteBranch.succeeded {
            let initialDivergence = try divergenceCounts(
                await command(
                    "git",
                    ["rev-list", "--left-right", "--count", "HEAD...origin/\(branch)"],
                    in: workspaceURL
                ),
                branch: branch
            )

            if initialDivergence.remote > 0 {
                await onProgress(.rebasingRemoteChanges)
                try requireSuccess(
                    await command("git", ["rebase", "origin/\(branch)"], in: workspaceURL),
                    operation: "rebase onto origin/\(branch)"
                )
                integratedRemoteChanges = true
            }

            let localAhead: Int
            if integratedRemoteChanges {
                localAhead = try divergenceCounts(
                    await command(
                        "git",
                        ["rev-list", "--left-right", "--count", "HEAD...origin/\(branch)"],
                        in: workspaceURL
                    ),
                    branch: branch
                ).local
            } else {
                localAhead = initialDivergence.local
            }

            if localAhead > 0 {
                await onProgress(.pushingLocalChanges)
                try requireSuccess(
                    try await authenticatedGitCommand(
                        ["push", "--set-upstream", "origin", branch],
                        in: workspaceURL
                    ),
                    operation: "push \(branch) to GitHub"
                )
                pushedChanges = true
            }
        } else {
            await onProgress(.pushingLocalChanges)
            try requireSuccess(
                try await authenticatedGitCommand(
                    ["push", "--set-upstream", "origin", branch],
                    in: workspaceURL
                ),
                operation: "push \(branch) to GitHub"
            )
            pushedChanges = true
        }

        return GitSynchronizationResult(
            committedChanges: committedChanges,
            remoteConfigured: true,
            integratedRemoteChanges: integratedRemoteChanges,
            pushedChanges: pushedChanges,
            summary: synchronizationSummary(
                integratedRemoteChanges: integratedRemoteChanges,
                pushedChanges: pushedChanges
            )
        )
    }

    private func command(_ tool: String, _ arguments: [String], in workspaceURL: URL?) async -> CommandResult {
        await runner.run(
            executable: environmentExecutable,
            arguments: [tool] + arguments,
            workingDirectory: workspaceURL
        )
    }

    private func authenticatedGitCommand(
        _ arguments: [String],
        in workspaceURL: URL
    ) async throws -> CommandResult {
        guard let token = try await credentials.validAccessToken(forceRefresh: false) else {
            throw GitCommandFailure(message: "The GitHub App connection expired. Connect it again.")
        }
        let credentialHelper = """
        !f() { printf '%s\\n' 'username=x-access-token' "password=$SHARED_LIBRARY_GITHUB_TOKEN"; }; f
        """
        return await runner.run(
            executable: environmentExecutable,
            arguments: [
                "git",
                "-c", "credential.helper=\(credentialHelper)",
                "-c", "credential.useHttpPath=true"
            ] + arguments,
            workingDirectory: workspaceURL,
            additionalEnvironment: [
                "SHARED_LIBRARY_GITHUB_TOKEN": token,
                "GIT_TERMINAL_PROMPT": "0"
            ]
        )
    }

    private func commitWorkspaceChanges(
        workspaceURL: URL,
        reason: String,
        onCommit: (@Sendable () async -> Void)? = nil
    ) async throws -> Bool {
        try requireSuccess(
            await command("git", ["add", "--all"], in: workspaceURL),
            operation: "stage workspace changes"
        )
        let stagedChanges = await command("git", ["diff", "--cached", "--quiet"], in: workspaceURL)
        switch stagedChanges.exitCode {
        case 0:
            return false
        case 1:
            await onCommit?()
            let commitReason = reason
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            let message = commitReason.isEmpty
                ? "Shared Library sync"
                : "Shared Library sync: \(commitReason)"
            try requireSuccess(
                await command("git", ["commit", "-m", message], in: workspaceURL),
                operation: "commit workspace changes"
            )
            return true
        default:
            throw failure(for: stagedChanges, operation: "check staged workspace changes")
        }
    }

    private func divergenceCounts(
        _ result: CommandResult,
        branch: String
    ) throws -> (local: Int, remote: Int) {
        try requireSuccess(result, operation: "compare local and origin/\(branch) history")
        let values = result.standardOutput
            .split(whereSeparator: { $0.isWhitespace })
            .compactMap { Int($0) }
        guard values.count == 2 else {
            throw GitCommandFailure(
                message: "Could not compare local and origin/\(branch) history. Git returned an unexpected result."
            )
        }
        return (local: values[0], remote: values[1])
    }

    private func synchronizationSummary(
        integratedRemoteChanges: Bool,
        pushedChanges: Bool
    ) -> String {
        switch (integratedRemoteChanges, pushedChanges) {
        case (true, true):
            return "Remote changes applied and local changes pushed."
        case (true, false):
            return "Remote changes applied."
        case (false, true):
            return "Local changes pushed."
        case (false, false):
            return "Everything is up to date."
        }
    }

    private func requireSuccess(_ result: CommandResult, operation: String) throws {
        guard result.succeeded else { throw failure(for: result, operation: operation) }
    }

    private func failure(for result: CommandResult, operation: String) -> GitCommandFailure {
        let detail = result.output.isEmpty ? "The command exited with status \(result.exitCode)." : result.output
        return GitCommandFailure(message: "Could not \(operation). \(detail)")
    }

    private func nonemptyOutput(_ result: CommandResult) -> String? {
        guard result.succeeded else { return nil }
        let value = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func ensureWorkspaceGitignore(workspaceURL: URL) throws {
        let url = workspaceURL.appendingPathComponent(".gitignore")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let lines = existing.components(separatedBy: .newlines)
        guard !lines.contains(".DS_Store") else { return }
        var updated = existing
        if !updated.isEmpty, !updated.hasSuffix("\n") { updated.append("\n") }
        updated.append(".DS_Store\n")
        try updated.write(to: url, atomically: true, encoding: .utf8)
    }
}

enum GitSyncState: Equatable, Sendable {
    case checking
    case ready(String)
    case syncing(String)
    case succeeded(String)
    case needsSetup(String)
    case unavailable(String)
    case failed(String)

    var message: String {
        switch self {
        case .checking:
            return "Checking Git and GitHub..."
        case .ready(let message), .syncing(let message), .succeeded(let message),
             .needsSetup(let message), .unavailable(let message), .failed(let message):
            return message
        }
    }

    var isBusy: Bool {
        switch self {
        case .checking, .syncing:
            return true
        default:
            return false
        }
    }
}

@MainActor
final class GitSyncCoordinator: ObservableObject {
    @Published private(set) var repositoryStatus = GitRepositoryStatus.unknown
    @Published private(set) var state = GitSyncState.checking

    private let engine: GitSyncEngine
    private var workspaceURL: URL
    private var operationTask: Task<Void, Never>?
    private var automaticSyncTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var pendingSyncReason: String?
    private var retryAttempt = 0

    private static let retryDelaySeconds = [5, 15, 60, 300]

    init(
        workspaceURL: URL,
        runner: any CommandRunning = ProcessCommandRunner(),
        credentials: any GitHubCredentialProviding = GitHubCredentialVault.shared
    ) {
        self.workspaceURL = workspaceURL.standardizedFileURL
        engine = GitSyncEngine(
            runner: runner,
            credentials: credentials
        )
    }

    func setWorkspaceURL(_ url: URL) {
        operationTask?.cancel()
        automaticSyncTask?.cancel()
        retryTask?.cancel()
        operationTask = nil
        automaticSyncTask = nil
        retryTask = nil
        pendingSyncReason = nil
        retryAttempt = 0
        workspaceURL = url.standardizedFileURL
        repositoryStatus = .unknown
        refreshStatus()
    }

    func refreshStatus() {
        guard operationTask == nil else { return }
        state = .checking
        let workspaceURL = workspaceURL
        operationTask = Task { [weak self] in
            guard let self else { return }
            let status = await engine.inspect(workspaceURL: workspaceURL)
            guard !Task.isCancelled else { return }
            repositoryStatus = status
            state = Self.state(for: status)
            finishOperation()
        }
    }

    func initializeRepository() {
        guard operationTask == nil else { return }
        state = .syncing("Initializing the workspace repository...")
        let workspaceURL = workspaceURL
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let status = try await engine.initializeRepository(workspaceURL: workspaceURL)
                guard !Task.isCancelled else { return }
                repositoryStatus = status
                state = Self.state(for: status)
            } catch {
                state = .failed(error.localizedDescription)
            }
            finishOperation()
        }
    }

    func connectRemote(_ value: String) {
        guard operationTask == nil else { return }
        guard let remote = Self.normalizedRemote(value) else {
            state = .failed("Enter a GitHub repository as owner/name or a valid Git remote URL.")
            return
        }

        state = .syncing("Connecting the GitHub repository...")
        let workspaceURL = workspaceURL
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let status = try await engine.connectRemote(remote, workspaceURL: workspaceURL)
                guard !Task.isCancelled else { return }
                repositoryStatus = status
                state = Self.state(for: status)
            } catch {
                state = .failed(error.localizedDescription)
            }
            finishOperation()
        }
    }

    func requestAutomaticSync(reason: String) {
        retryTask?.cancel()
        retryTask = nil
        retryAttempt = 0
        pendingSyncReason = reason
        schedulePendingSync()
    }

    static func isRetryableSyncError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return [
            "could not fetch",
            "could not push",
            "could not resolve host",
            "connection reset",
            "connection timed out",
            "network is unreachable",
            "temporarily unavailable"
        ].contains(where: message.contains)
    }

    private func schedulePendingSync() {
        automaticSyncTask?.cancel()
        guard operationTask == nil,
              repositoryStatus.isRepository,
              pendingSyncReason != nil else {
            automaticSyncTask = nil
            return
        }
        state = .syncing("Background sync queued...")
        automaticSyncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            automaticSyncTask = nil
            guard let reason = pendingSyncReason else { return }
            pendingSyncReason = nil
            startSync(reason: reason)
        }
    }

    static func normalizedRemote(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isWhitespace }) else { return nil }

        if trimmed.hasPrefix("https://github.com/") {
            return trimmed.hasSuffix(".git") ? trimmed : "\(trimmed).git"
        }
        if trimmed.hasPrefix("git@github.com:") {
            let path = String(trimmed.dropFirst("git@github.com:".count))
            guard path.split(separator: "/").count == 2 else { return nil }
            return "https://github.com/\(path.hasSuffix(".git") ? path : "\(path).git")"
        }

        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        let repository = parts[1].hasSuffix(".git") ? String(parts[1]) : "\(parts[1]).git"
        return "https://github.com/\(parts[0])/\(repository)"
    }

    private func startSync(reason: String) {
        if operationTask != nil {
            pendingSyncReason = reason
            return
        }

        state = .syncing("Synchronizing workspace changes...")
        let workspaceURL = workspaceURL
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await engine.synchronize(
                    workspaceURL: workspaceURL,
                    reason: reason,
                    onProgress: { phase in
                        await self.showSyncProgress(phase)
                    }
                )
                guard !Task.isCancelled else { return }
                retryTask?.cancel()
                retryTask = nil
                retryAttempt = 0
                repositoryStatus = await engine.inspect(workspaceURL: workspaceURL)
                state = result.remoteConfigured
                    ? .succeeded("\(result.summary) Checked at \(Self.shortTime(Date())).")
                    : .needsSetup(result.summary)
                if result.integratedRemoteChanges {
                    NotificationCenter.default.post(name: .libraryDidChange, object: nil)
                }
                NotificationCenter.default.post(
                    name: .workspaceDidSynchronize,
                    object: workspaceURL
                )
            } catch {
                guard !Task.isCancelled else { return }
                repositoryStatus = await engine.inspect(workspaceURL: workspaceURL)
                if let delay = scheduleRetryIfNeeded(for: error, reason: reason) {
                    state = .failed("\(error.localizedDescription) Retrying in \(delay) seconds.")
                } else {
                    state = .failed(error.localizedDescription)
                }
            }
            finishOperation()
        }
    }

    private func scheduleRetryIfNeeded(for error: Error, reason: String) -> Int? {
        guard Self.isRetryableSyncError(error),
              retryAttempt < Self.retryDelaySeconds.count else { return nil }
        let delay = Self.retryDelaySeconds[retryAttempt]
        retryAttempt += 1
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            retryTask = nil
            pendingSyncReason = reason
            schedulePendingSync()
        }
        return delay
    }

    private func showSyncProgress(_ phase: GitSynchronizationPhase) {
        state = .syncing(phase.message)
    }

    private func finishOperation() {
        operationTask = nil
        schedulePendingSync()
    }

    private static func state(for status: GitRepositoryStatus) -> GitSyncState {
        guard status.gitAvailable else {
            return .unavailable("Git is not installed or is not available on PATH.")
        }
        guard status.isRepository else {
            return .needsSetup("Initialize the workspace as a Git repository.")
        }
        guard status.hasRemote else {
            return .needsSetup("The local repository is ready. Connect a GitHub repository to sync.")
        }
        guard status.githubAppConfigured else {
            return .needsSetup("Enter the GitHub App Client ID in Settings.")
        }
        guard status.githubAuthenticated else {
            return .needsSetup("Connect the GitHub App to enable background synchronization.")
        }
        return .ready("Background sync is active on \(status.branch ?? "the current branch").")
    }

    private static func shortTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
