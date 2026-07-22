import XCTest
@testable import SharedLibrary

final class GitHubPeopleStoreTests: XCTestCase {
    func testGitHubClientReadsOnlyStableIdentityAndDisplayName() async throws {
        let response = """
        {
          "data": {
            "viewer": { "id": "viewer-id", "login": "jonsch1", "name": "Jonathan Schaul" },
            "organization": {
              "membersWithRole": {
                "nodes": [
                  { "id": "person-2", "login": "pablormier", "name": "Pablo Rodriguez-Mier" },
                  { "id": "viewer-id", "login": "jonsch1", "name": null }
                ],
                "pageInfo": { "hasNextPage": false, "endCursor": null }
              }
            }
          }
        }
        """
        let runner = PeopleCommandRunner(responses: [.success(response)])
        let client = GitHubPeopleClient(runner: runner)

        let roster = try await client.fetchRoster(organization: "saezlab")

        XCTAssertEqual(roster.organization, "saezlab")
        XCTAssertEqual(roster.viewer.githubID, "viewer-id")
        XCTAssertEqual(roster.people.count, 2)
        XCTAssertEqual(roster.people.first { $0.githubID == "viewer-id" }?.displayName, "jonsch1")
        let calls = await runner.recordedArguments()
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(calls[0].contains("organization=saezlab"))
    }

    func testPeopleDirectoryStoresOnlyRequestedProfileFields() throws {
        let sharedRoot = temporarySharedRoot()
        defer { try? FileManager.default.removeItem(at: sharedRoot) }
        let store = PeopleDirectoryStore()
        let person = SharedPerson(
            githubID: "stable-id",
            login: "jonsch1",
            displayName: "Jonathan Schaul"
        )

        let people = try store.synchronize(people: [person], sharedWorkspaceURL: sharedRoot)

        XCTAssertEqual(people, [person])
        let personRoot = sharedRoot.appendingPathComponent("people/jonsch1", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: personRoot.appendingPathComponent("shared").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: personRoot.appendingPathComponent("shared_with").path))
        let data = try Data(contentsOf: personRoot.appendingPathComponent("profile.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["githubID", "displayName"])
        XCTAssertEqual(json["githubID"] as? String, "stable-id")
        XCTAssertEqual(json["displayName"] as? String, "Jonathan Schaul")
    }

    func testPeopleDirectoryRenamesLoginFolderAndPreservesSharingHistory() throws {
        let sharedRoot = temporarySharedRoot()
        defer { try? FileManager.default.removeItem(at: sharedRoot) }
        let store = PeopleDirectoryStore()
        let original = SharedPerson(githubID: "stable-id", login: "old-login", displayName: "Person")
        try store.synchronize(people: [original], sharedWorkspaceURL: sharedRoot)
        let marker = sharedRoot.appendingPathComponent("people/old-login/shared/reference.json")
        try "history".write(to: marker, atomically: true, encoding: .utf8)

        let renamed = SharedPerson(githubID: "stable-id", login: "new-login", displayName: "New Name")
        let people = try store.synchronize(people: [renamed], sharedWorkspaceURL: sharedRoot)

        XCTAssertEqual(people, [renamed])
        XCTAssertFalse(FileManager.default.fileExists(atPath: sharedRoot.appendingPathComponent("people/old-login").path))
        XCTAssertEqual(
            try String(contentsOf: sharedRoot.appendingPathComponent("people/new-login/shared/reference.json")),
            "history"
        )
    }

    private func temporarySharedRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("people-store-\(UUID().uuidString)", isDirectory: true)
    }
}

private actor PeopleCommandRunner: CommandRunning {
    private var responses: [CommandResult]
    private var calls: [[String]] = []

    init(responses: [CommandResult]) {
        self.responses = responses
    }

    func run(executable: String, arguments: [String], workingDirectory: URL?) async -> CommandResult {
        calls.append(arguments)
        guard !responses.isEmpty else {
            return .failure(message: "Unexpected command")
        }
        return responses.removeFirst()
    }

    func recordedArguments() -> [[String]] { calls }
}

private extension CommandResult {
    static func success(_ output: String = "") -> CommandResult {
        CommandResult(exitCode: 0, standardOutput: output, standardError: "")
    }

    static func failure(exitCode: Int32 = 1, message: String = "") -> CommandResult {
        CommandResult(exitCode: exitCode, standardOutput: "", standardError: message)
    }
}
