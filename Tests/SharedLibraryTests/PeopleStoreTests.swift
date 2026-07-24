import XCTest
@testable import SharedLibrary

final class PeopleStoreTests: XCTestCase {
    func testRegistrationWritesSinglePeopleDocument() throws {
        let sharedRoot = temporarySharedRoot()
        defer { try? FileManager.default.removeItem(at: sharedRoot) }
        let store = PeopleDirectoryStore()

        let person = try store.register(
            userID: "stable-id",
            username: "Jonathan_Schaul",
            sharedWorkspaceURL: sharedRoot
        )

        XCTAssertEqual(person, SharedPerson(userID: "stable-id", username: "jonathan_schaul"))
        let data = try Data(contentsOf: sharedRoot.appendingPathComponent("people.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["schemaVersion", "updatedAt", "people"])
        XCTAssertEqual(json["schemaVersion"] as? Int, 2)
        let profiles = try XCTUnwrap(json["people"] as? [[String: Any]])
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0]["userID"] as? String, "stable-id")
        XCTAssertEqual(profiles[0]["username"] as? String, "jonathan_schaul")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: sharedRoot.appendingPathComponent("people").path
        ))
    }

    func testUsernameRenameUpdatesSameStableIdentity() throws {
        let sharedRoot = temporarySharedRoot()
        defer { try? FileManager.default.removeItem(at: sharedRoot) }
        let store = PeopleDirectoryStore()
        try store.register(
            userID: "stable-id",
            username: "old-name",
            sharedWorkspaceURL: sharedRoot
        )

        let renamed = try store.register(
            userID: "stable-id",
            username: "new-name",
            sharedWorkspaceURL: sharedRoot
        )

        XCTAssertEqual(renamed, SharedPerson(userID: "stable-id", username: "new-name"))
        XCTAssertEqual(
            try store.people(sharedWorkspaceURL: sharedRoot),
            [SharedPerson(userID: "stable-id", username: "new-name")]
        )
    }

    func testDuplicateUsernameIsRejectedCaseInsensitively() throws {
        let sharedRoot = temporarySharedRoot()
        defer { try? FileManager.default.removeItem(at: sharedRoot) }
        let store = PeopleDirectoryStore()
        try store.register(
            userID: "first-id",
            username: "researcher",
            sharedWorkspaceURL: sharedRoot
        )

        XCTAssertThrowsError(
            try store.register(
                userID: "second-id",
                username: "Researcher",
                sharedWorkspaceURL: sharedRoot
            )
        ) { error in
            XCTAssertEqual(error as? PeopleDirectoryError, .usernameTaken("researcher"))
        }
    }

    func testInvalidPeopleDocumentIsRejectedInsteadOfMigrated() throws {
        let sharedRoot = temporarySharedRoot()
        defer { try? FileManager.default.removeItem(at: sharedRoot) }
        try FileManager.default.createDirectory(at: sharedRoot, withIntermediateDirectories: true)
        try #"{"schemaVersion":1,"people":[]}"#.write(
            to: sharedRoot.appendingPathComponent("people.json"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertThrowsError(
            try PeopleDirectoryStore().people(sharedWorkspaceURL: sharedRoot)
        ) { error in
            XCTAssertEqual(error as? PeopleDirectoryError, .invalidDirectory)
        }
    }

    private func temporarySharedRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("people-store-\(UUID().uuidString)", isDirectory: true)
    }
}
