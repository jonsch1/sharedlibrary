import BrieflyCore
import Foundation

struct AppEnvironment {
    private static let uiTestingArgument = "--ui-testing"
    private static let uiTestResetArgument = "--ui-test-reset"
    private static let uiTestScenarioArgument = "--ui-test-scenario"

    let isUITesting: Bool
    let resetsUITestLibrary: Bool
    let uiTestScenario: String

    static func current(arguments: [String] = ProcessInfo.processInfo.arguments) -> Self {
        let scenario: String
        if let index = arguments.firstIndex(of: uiTestScenarioArgument),
           arguments.indices.contains(index + 1) {
            scenario = sanitizedScenario(arguments[index + 1])
        } else {
            scenario = "library"
        }
        return Self(
            isUITesting: arguments.contains(uiTestingArgument),
            resetsUITestLibrary: arguments.contains(uiTestResetArgument),
            uiTestScenario: scenario
        )
    }

    func prepareUITestLibrary() throws -> URL {
        precondition(isUITesting)
        if resetsUITestLibrary {
            UserDefaults.standard.removeObject(forKey: "BrieflyMobileTab")
        }
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "BrieflyUITests", directoryHint: .isDirectory)
            .appending(path: uiTestScenario, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let databaseURL = directory.appending(path: "library.sqlite3")
        if resetsUITestLibrary {
            for url in [
                databaseURL,
                URL(filePath: databaseURL.path + "-wal"),
                URL(filePath: databaseURL.path + "-shm")
            ] where FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }

        let database = try SQLiteLibrary(databaseURL: databaseURL)
        if try database.isEmpty() {
            try seedUITestLibrary(database)
        }
        return databaseURL
    }

    private func seedUITestLibrary(_ database: SQLiteLibrary) throws {
        let createdAt = Date(timeIntervalSince1970: 1_767_268_800)
        let channelSource = "https://fixture.example/feed"
        try database.replaceTopicDefinitions([
            LibraryTopicDefinition(id: "architecture", title: "Architecture"),
            LibraryTopicDefinition(id: "testing", title: "Testing")
        ])
        _ = try database.createDocument(
            title: "Architecture of Small Systems",
            body: "# Architecture of Small Systems\n\nThe source explains how narrow boundaries keep software adaptable.",
            texts: [
                .source: "# Architecture of Small Systems\n\nThe source explains how narrow boundaries keep software adaptable.",
                .concise: "# Small systems\n\nClear ownership makes change safer.",
                .detailed: "# Small systems in detail\n\nStable boundaries isolate change while preserving user-visible behavior."
            ],
            type: "link",
            sourceURL: "https://fixture.example/architecture",
            topicIDs: ["architecture"],
            tags: ["testing"],
            id: "fixture:article",
            captureID: "FIXTURE-ARTICLE",
            createdAt: createdAt,
            addToOutbox: false
        )
        _ = try database.createDocument(
            title: "Designing Durable Tests",
            body: "# Designing Durable Tests\n\nAssert outcomes instead of presentation details.",
            texts: [
                .source: "# Designing Durable Tests\n\nAssert outcomes instead of presentation details.",
                .concise: "# Durable tests\n\nTest observable behavior and persisted state."
            ],
            type: "document",
            topicIDs: ["testing"],
            tags: ["quality"],
            id: "fixture:testing",
            captureID: "FIXTURE-TESTING",
            createdAt: createdAt.addingTimeInterval(60),
            addToOutbox: false
        )
        let channelArticle = try database.createDocument(
            title: "A Feed Story About Boundaries",
            body: "# A Feed Story About Boundaries\n\nA channel story used by the application tour.",
            texts: [
                .source: "# A Feed Story About Boundaries\n\nA channel story used by the application tour.",
                .concise: "# Feed boundaries\n\nA channel item remains linked to its source."
            ],
            type: "voice_brief_source",
            sourceURL: "https://fixture.example/feed-story",
            id: "fixture:channel-article",
            captureID: "FIXTURE-CHANNEL-ARTICLE",
            createdAt: createdAt.addingTimeInterval(90),
            addToOutbox: false
        )
        try database.saveChannelRecords([
            SQLiteChannelRecord(
                source: channelSource,
                title: "Fixture Engineering Feed",
                kind: .feed,
                schedule: "manual",
                lastCheckedAt: ISO8601DateFormatter().string(from: createdAt),
                retrievalCount: 5,
                canLoadMore: false,
                seen: ["fixture-item"],
                items: [
                    LibraryChannelItem(
                        id: "fixture-item",
                        title: channelArticle.title,
                        url: "https://fixture.example/feed-story",
                        publishedAt: ISO8601DateFormatter().string(from: createdAt),
                        entryID: channelArticle.id,
                        ingestedAt: ISO8601DateFormatter().string(from: createdAt)
                    )
                ]
            )
        ])
        _ = try database.saveVoiceBrief(LibraryVoiceBriefDraft(
            id: "fixture:brief",
            title: "Fixture Daily Brief",
            schedule: "manual",
            length: LibraryVariant.concise.rawValue,
            sources: [channelSource],
            prioritizeForMe: false
        ))
        _ = try database.createDocument(
            title: "Fixture Daily Brief — Architecture",
            body: "# Fixture Daily Brief\n\nClear boundaries make systems easier to change.",
            texts: [
                .concise: "# Fixture Daily Brief\n\nClear boundaries make systems easier to change.",
                .detailed: "# Fixture Daily Brief\n\nThe saved stories emphasize narrow interfaces and durable journey tests."
            ],
            type: "voice_brief_episode",
            voiceBriefID: "fixture:brief",
            sourceIDs: [channelArticle.id],
            sourceURLs: ["https://fixture.example/feed-story"],
            id: "fixture:brief-episode",
            captureID: "FIXTURE-BRIEF-EPISODE",
            createdAt: createdAt.addingTimeInterval(120),
            addToOutbox: false
        )
    }

    private static func sanitizedScenario(_ value: String) -> String {
        let sanitized = value.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
                ? Character(String(scalar))
                : "-"
        }
        let result = String(sanitized).prefix(80)
        return result.isEmpty ? "library" : String(result)
    }
}
