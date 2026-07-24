import Combine
import Foundation

struct SharedPerson: Identifiable, Hashable, Sendable {
    var userID: String
    var username: String

    var id: String { userID }
}

private struct SharedPersonProfile: Codable, Equatable {
    var userID: String
    var username: String
    var updatedAt: Date
}

private struct SharedPeopleDocument: Codable, Equatable {
    static let schemaVersion = 2

    var schemaVersion: Int
    var people: [SharedPersonProfile]
    var updatedAt: Date
}

enum PeopleDirectoryError: LocalizedError, Equatable {
    case invalidUsername
    case usernameTaken(String)
    case invalidDirectory

    var errorDescription: String? {
        switch self {
        case .invalidUsername:
            return "Use 2–32 letters, numbers, hyphens, or underscores. Start and end with a letter or number."
        case .usernameTaken(let username):
            return "@\(username) is already used by another person in this shared library."
        case .invalidDirectory:
            return "The shared people directory is invalid."
        }
    }
}

final class PeopleDirectoryStore {
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    static func normalizedUsername(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func isValidUsername(_ value: String) -> Bool {
        let value = normalizedUsername(value)
        guard (2...32).contains(value.count),
              value.first?.isLetter == true || value.first?.isNumber == true,
              value.last?.isLetter == true || value.last?.isNumber == true else {
            return false
        }
        return value.allSatisfy { character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
        }
    }

    func people(sharedWorkspaceURL: URL) throws -> [SharedPerson] {
        let document = try readDocument(sharedWorkspaceURL: sharedWorkspaceURL)
        guard document.schemaVersion == SharedPeopleDocument.schemaVersion else {
            throw PeopleDirectoryError.invalidDirectory
        }
        var peopleByID: [String: SharedPerson] = [:]
        for profile in document.people {
            let username = Self.normalizedUsername(profile.username)
            guard !profile.userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  Self.isValidUsername(username) else {
                continue
            }
            peopleByID[profile.userID] = SharedPerson(
                userID: profile.userID,
                username: username
            )
        }
        return peopleByID.values.sorted {
            $0.username.localizedStandardCompare($1.username) == .orderedAscending
        }
    }

    @discardableResult
    func register(
        userID: String,
        username rawUsername: String,
        sharedWorkspaceURL: URL
    ) throws -> SharedPerson {
        let username = Self.normalizedUsername(rawUsername)
        guard Self.isValidUsername(username),
              !userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PeopleDirectoryError.invalidUsername
        }

        var document = try readDocument(sharedWorkspaceURL: sharedWorkspaceURL)
        guard document.schemaVersion == SharedPeopleDocument.schemaVersion else {
            throw PeopleDirectoryError.invalidDirectory
        }
        if let owner = document.people.first(where: {
            Self.normalizedUsername($0.username).caseInsensitiveCompare(username) == .orderedSame
                && $0.userID != userID
        }) {
            throw PeopleDirectoryError.usernameTaken(Self.normalizedUsername(owner.username))
        }

        let now = Date()
        document.people.removeAll { $0.userID == userID }
        document.people.append(
            SharedPersonProfile(
                userID: userID,
                username: username,
                updatedAt: now
            )
        )
        document.people.sort {
            Self.normalizedUsername($0.username)
                .localizedStandardCompare(Self.normalizedUsername($1.username)) == .orderedAscending
        }
        document.schemaVersion = SharedPeopleDocument.schemaVersion
        document.updatedAt = now
        try write(document, sharedWorkspaceURL: sharedWorkspaceURL)
        return SharedPerson(userID: userID, username: username)
    }

    private func readDocument(sharedWorkspaceURL: URL) throws -> SharedPeopleDocument {
        let url = peopleURL(sharedWorkspaceURL: sharedWorkspaceURL)
        guard fileManager.fileExists(atPath: url.path) else {
            return SharedPeopleDocument(
                schemaVersion: SharedPeopleDocument.schemaVersion,
                people: [],
                updatedAt: Date()
            )
        }
        do {
            return try decoder.decode(SharedPeopleDocument.self, from: Data(contentsOf: url))
        } catch {
            throw PeopleDirectoryError.invalidDirectory
        }
    }

    private func write(
        _ document: SharedPeopleDocument,
        sharedWorkspaceURL: URL
    ) throws {
        try fileManager.createDirectory(at: sharedWorkspaceURL, withIntermediateDirectories: true)
        try encoder.encode(document).write(
            to: peopleURL(sharedWorkspaceURL: sharedWorkspaceURL),
            options: .atomic
        )
    }

    private func peopleURL(sharedWorkspaceURL: URL) -> URL {
        sharedWorkspaceURL.appendingPathComponent("people.json")
    }
}

enum PeopleDirectoryState: Equatable {
    case idle(String)
    case succeeded(String)
    case failed(String)

    var message: String {
        switch self {
        case .idle(let message), .succeeded(let message), .failed(let message):
            return message
        }
    }
}

@MainActor
final class PeopleStore: ObservableObject {
    @Published private(set) var people: [SharedPerson] = []
    @Published private(set) var state: PeopleDirectoryState

    private let directoryStore: PeopleDirectoryStore
    private let settings: AppSettings
    private var sharedWorkspaceURL: URL

    init(
        sharedWorkspaceURL: URL,
        settings: AppSettings,
        directoryStore: PeopleDirectoryStore = PeopleDirectoryStore()
    ) {
        self.sharedWorkspaceURL = sharedWorkspaceURL.standardizedFileURL
        self.settings = settings
        self.directoryStore = directoryStore
        state = .idle("Choose a username to join this shared library.")
        reloadFromDisk()
        restoreCurrentUserIfPossible()
    }

    var currentUser: SharedPerson? {
        guard let currentID = settings.currentUserID else { return nil }
        return people.first { $0.userID == currentID }
    }

    func person(userID: String) -> SharedPerson? {
        people.first { $0.userID == userID }
    }

    func setSharedWorkspaceURL(_ url: URL) {
        sharedWorkspaceURL = url.standardizedFileURL
        reloadFromDisk()
        restoreCurrentUserIfPossible()
    }

    func reloadFromDisk() {
        do {
            people = try directoryStore.people(sharedWorkspaceURL: sharedWorkspaceURL)
            if let currentUser {
                state = .idle("Signed in to the shared library as @\(currentUser.username).")
            } else {
                state = .idle("Choose a username to join this shared library.")
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func saveUsername(
        _ username: String,
        onSharedWorkspaceChange: @escaping @MainActor () -> Void
    ) {
        do {
            let userID = settings.currentUserID ?? UUID().uuidString.lowercased()
            let person = try directoryStore.register(
                userID: userID,
                username: username,
                sharedWorkspaceURL: sharedWorkspaceURL
            )
            settings.currentUserID = userID
            settings.username = person.username
            people = try directoryStore.people(sharedWorkspaceURL: sharedWorkspaceURL)
            state = .succeeded("@\(person.username) is saved in people.json.")
            onSharedWorkspaceChange()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func restoreCurrentUserIfPossible() {
        guard let currentID = settings.currentUserID,
              let person = people.first(where: { $0.userID == currentID }) else {
            return
        }
        settings.username = person.username
        state = .idle("Signed in to the shared library as @\(person.username).")
    }
}
