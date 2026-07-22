import Combine
import Foundation

struct SharedPerson: Identifiable, Hashable, Sendable {
    var githubID: String
    var login: String
    var displayName: String

    var id: String { githubID }
}

private struct SharedPersonProfile: Codable, Equatable {
    var githubID: String
    var displayName: String
}

struct GitHubPeopleRoster: Equatable, Sendable {
    var organization: String
    var viewer: SharedPerson
    var people: [SharedPerson]
}

enum GitHubPeopleError: LocalizedError, Equatable {
    case invalidOrganization
    case organizationNotFound(String)
    case invalidResponse
    case commandFailed(String)
    case invalidLogin(String)
    case conflictingPerson(String)

    var errorDescription: String? {
        switch self {
        case .invalidOrganization:
            return "Enter a GitHub organization name using letters, numbers, or hyphens."
        case .organizationNotFound(let organization):
            return "GitHub could not find the organization \(organization), or your account cannot access it."
        case .invalidResponse:
            return "GitHub returned an invalid people response."
        case .commandFailed(let message):
            return message
        case .invalidLogin(let login):
            return "GitHub returned an invalid login: \(login)."
        case .conflictingPerson(let login):
            return "The people folder for @\(login) belongs to a different GitHub account."
        }
    }
}

actor GitHubPeopleClient {
    private let runner: any CommandRunning
    private let environmentExecutable = "/usr/bin/env"

    init(runner: any CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    func fetchRoster(organization: String) async throws -> GitHubPeopleRoster {
        let normalizedOrganization = organization.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidOrganization(normalizedOrganization) else {
            throw GitHubPeopleError.invalidOrganization
        }

        var viewer: SharedPerson?
        var peopleByID: [String: SharedPerson] = [:]
        var cursor: String?

        repeat {
            var arguments = [
                "gh", "api", "graphql",
                "-f", "query=\(Self.query)",
                "-F", "organization=\(normalizedOrganization)"
            ]
            if let cursor {
                arguments.append(contentsOf: ["-F", "endCursor=\(cursor)"])
            }

            let result = await runner.run(
                executable: environmentExecutable,
                arguments: arguments,
                workingDirectory: nil
            )
            guard result.succeeded else {
                let detail = result.output.isEmpty
                    ? "GitHub CLI exited with status \(result.exitCode)."
                    : result.output
                throw GitHubPeopleError.commandFailed("Could not sync people from GitHub. \(detail)")
            }
            guard let data = result.standardOutput.data(using: .utf8),
                  let page = try? JSONDecoder().decode(GraphQLResponse.self, from: data) else {
                throw GitHubPeopleError.invalidResponse
            }
            if let error = page.errors?.first?.message {
                throw GitHubPeopleError.commandFailed("Could not sync people from GitHub. \(error)")
            }
            guard let payload = page.data,
                  let organizationPayload = payload.organization else {
                throw GitHubPeopleError.organizationNotFound(normalizedOrganization)
            }

            if viewer == nil {
                viewer = try Self.person(from: payload.viewer)
            }
            for node in organizationPayload.membersWithRole.nodes {
                let person = try Self.person(from: node)
                peopleByID[person.githubID] = person
            }

            let pageInfo = organizationPayload.membersWithRole.pageInfo
            cursor = pageInfo.hasNextPage ? pageInfo.endCursor : nil
        } while cursor != nil

        guard let viewer else { throw GitHubPeopleError.invalidResponse }
        return GitHubPeopleRoster(
            organization: normalizedOrganization,
            viewer: viewer,
            people: peopleByID.values.sorted(by: Self.peopleSort)
        )
    }

    private static func person(from node: UserNode) throws -> SharedPerson {
        guard isValidLogin(node.login) else {
            throw GitHubPeopleError.invalidLogin(node.login)
        }
        let name = node.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return SharedPerson(
            githubID: node.id,
            login: node.login,
            displayName: name.isEmpty ? node.login : name
        )
    }

    private static func peopleSort(_ lhs: SharedPerson, _ rhs: SharedPerson) -> Bool {
        let comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
        return comparison == .orderedSame
            ? lhs.login.localizedStandardCompare(rhs.login) == .orderedAscending
            : comparison == .orderedAscending
    }

    private static func isValidOrganization(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 39 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    static func isValidLogin(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 39,
              value.first != "-", value.last != "-" else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static let query = """
    query($organization: String!, $endCursor: String) {
      viewer { id login name }
      organization(login: $organization) {
        membersWithRole(first: 100, after: $endCursor) {
          nodes { id login name }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
    """

    private struct GraphQLResponse: Decodable {
        var data: ResponseData?
        var errors: [ResponseError]?
    }

    private struct ResponseData: Decodable {
        var viewer: UserNode
        var organization: OrganizationNode?
    }

    private struct ResponseError: Decodable {
        var message: String
    }

    private struct UserNode: Decodable {
        var id: String
        var login: String
        var name: String?
    }

    private struct OrganizationNode: Decodable {
        var membersWithRole: MemberConnection
    }

    private struct MemberConnection: Decodable {
        var nodes: [UserNode]
        var pageInfo: PageInfo
    }

    private struct PageInfo: Decodable {
        var hasNextPage: Bool
        var endCursor: String?
    }
}

final class PeopleDirectoryStore {
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
    }

    func people(sharedWorkspaceURL: URL) throws -> [SharedPerson] {
        let root = peopleRoot(sharedWorkspaceURL: sharedWorkspaceURL)
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        .compactMap { directory -> SharedPerson? in
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true,
                  values.isSymbolicLink != true,
                  GitHubPeopleClient.isValidLogin(directory.lastPathComponent) else { return nil }
            let profileURL = directory.appendingPathComponent("profile.json")
            guard let data = try? Data(contentsOf: profileURL),
                  let profile = try? decoder.decode(SharedPersonProfile.self, from: data) else { return nil }
            return SharedPerson(
                githubID: profile.githubID,
                login: directory.lastPathComponent,
                displayName: profile.displayName
            )
        }
        .sorted {
            let comparison = $0.displayName.localizedStandardCompare($1.displayName)
            return comparison == .orderedSame
                ? $0.login.localizedStandardCompare($1.login) == .orderedAscending
                : comparison == .orderedAscending
        }
    }

    @discardableResult
    func synchronize(
        people incomingPeople: [SharedPerson],
        sharedWorkspaceURL: URL
    ) throws -> [SharedPerson] {
        let root = peopleRoot(sharedWorkspaceURL: sharedWorkspaceURL)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        var existingByID: [String: URL] = [:]
        for person in try people(sharedWorkspaceURL: sharedWorkspaceURL) {
            if existingByID[person.githubID] == nil {
                existingByID[person.githubID] = root.appendingPathComponent(person.login, isDirectory: true)
            }
        }

        for person in incomingPeople {
            guard GitHubPeopleClient.isValidLogin(person.login) else {
                throw GitHubPeopleError.invalidLogin(person.login)
            }
            let desiredDirectory = root.appendingPathComponent(person.login, isDirectory: true)
            if let existingDirectory = existingByID[person.githubID],
               existingDirectory.standardizedFileURL != desiredDirectory.standardizedFileURL {
                if fileManager.fileExists(atPath: desiredDirectory.path) {
                    let desiredProfile = try profile(at: desiredDirectory)
                    guard desiredProfile.githubID == person.githubID else {
                        throw GitHubPeopleError.conflictingPerson(person.login)
                    }
                } else {
                    try fileManager.moveItem(at: existingDirectory, to: desiredDirectory)
                }
                existingByID[person.githubID] = desiredDirectory
            } else if fileManager.fileExists(atPath: desiredDirectory.path),
                      let existingProfile = try? profile(at: desiredDirectory),
                      existingProfile.githubID != person.githubID {
                throw GitHubPeopleError.conflictingPerson(person.login)
            }

            try fileManager.createDirectory(
                at: desiredDirectory.appendingPathComponent("shared", isDirectory: true),
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: desiredDirectory.appendingPathComponent("shared_with", isDirectory: true),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(
                SharedPersonProfile(githubID: person.githubID, displayName: person.displayName)
            )
            try data.write(
                to: desiredDirectory.appendingPathComponent("profile.json"),
                options: .atomic
            )
        }

        return try people(sharedWorkspaceURL: sharedWorkspaceURL)
    }

    private func profile(at directory: URL) throws -> SharedPersonProfile {
        let data = try Data(contentsOf: directory.appendingPathComponent("profile.json"))
        return try decoder.decode(SharedPersonProfile.self, from: data)
    }

    private func peopleRoot(sharedWorkspaceURL: URL) -> URL {
        sharedWorkspaceURL.appendingPathComponent("people", isDirectory: true)
    }
}

enum GitHubPeopleSyncState: Equatable {
    case idle(String)
    case syncing(String)
    case succeeded(String)
    case failed(String)

    var message: String {
        switch self {
        case .idle(let message), .syncing(let message),
             .succeeded(let message), .failed(let message):
            return message
        }
    }

    var isBusy: Bool {
        if case .syncing = self { return true }
        return false
    }
}

@MainActor
final class GitHubPeopleStore: ObservableObject {
    @Published private(set) var people: [SharedPerson] = []
    @Published private(set) var state: GitHubPeopleSyncState

    private let client: GitHubPeopleClient
    private let directoryStore: PeopleDirectoryStore
    private let settings: AppSettings
    private var sharedWorkspaceURL: URL
    private var syncTask: Task<Void, Never>?

    init(
        sharedWorkspaceURL: URL,
        settings: AppSettings,
        client: GitHubPeopleClient = GitHubPeopleClient(),
        directoryStore: PeopleDirectoryStore = PeopleDirectoryStore()
    ) {
        self.sharedWorkspaceURL = sharedWorkspaceURL.standardizedFileURL
        self.settings = settings
        self.client = client
        self.directoryStore = directoryStore
        if let date = settings.githubPeopleLastSyncedAt {
            state = .idle("Last synced \(date.formatted(date: .abbreviated, time: .shortened)).")
        } else {
            state = .idle("People have not been synced yet.")
        }
        reloadFromDisk()
    }

    var currentUser: SharedPerson? {
        guard let currentID = settings.currentGitHubUserID else { return nil }
        return people.first { $0.githubID == currentID }
    }

    func person(githubID: String) -> SharedPerson? {
        people.first { $0.githubID == githubID }
    }

    func setSharedWorkspaceURL(_ url: URL) {
        syncTask?.cancel()
        syncTask = nil
        sharedWorkspaceURL = url.standardizedFileURL
        reloadFromDisk()
    }

    func reloadFromDisk() {
        do {
            people = try directoryStore.people(sharedWorkspaceURL: sharedWorkspaceURL)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func synchronize(
        organization: String,
        onRepositoryChange: @escaping @MainActor () -> Void
    ) {
        guard syncTask == nil else { return }
        state = .syncing("Syncing people from GitHub...")
        let sharedWorkspaceURL = sharedWorkspaceURL
        syncTask = Task { [weak self] in
            guard let self else { return }
            do {
                let roster = try await client.fetchRoster(organization: organization)
                guard !Task.isCancelled else { return }
                let updatedPeople = try directoryStore.synchronize(
                    people: roster.people,
                    sharedWorkspaceURL: sharedWorkspaceURL
                )
                settings.githubPeopleOrganization = roster.organization
                settings.currentGitHubUserID = roster.viewer.githubID
                settings.githubPeopleLastSyncedAt = Date()
                people = updatedPeople
                state = .succeeded("Synced \(people.count) people from \(roster.organization).")
                onRepositoryChange()
            } catch {
                guard !Task.isCancelled else { return }
                state = .failed(error.localizedDescription)
            }
            syncTask = nil
        }
    }
}
