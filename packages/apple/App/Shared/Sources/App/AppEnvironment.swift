import BrieflyCore
import Foundation

struct AppEnvironment {
    private static let uiTestingArgument = "--ui-testing"
    private static let uiTestResetArgument = "--ui-test-reset"
    private static let uiTestScenarioArgument = "--ui-test-scenario"
    private static let appReviewTestingArgument = "--app-review-testing"

    let isUITesting: Bool
    let isAppReviewTesting: Bool
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
            isAppReviewTesting: arguments.contains(appReviewTestingArgument),
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
            try seedSampleLibrary(database)
        }
        return databaseURL
    }

    func prepareAppReviewLibrary() throws -> URL {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "BrieflyAppReview", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let databaseURL = directory.appending(path: "library.sqlite3")
        let database = try SQLiteLibrary(databaseURL: databaseURL)
        if try database.isEmpty() {
            try seedSampleLibrary(database)
        }
        return databaseURL
    }

    func seedSampleLibrary(_ database: SQLiteLibrary) throws {
        let createdAt = Date(timeIntervalSince1970: 1_767_268_800)
        let channelSource = "https://fixture.example/feed"
        try database.replaceTopicDefinitions([
            LibraryTopicDefinition(id: "curiosity", title: "Curiosity"),
            LibraryTopicDefinition(id: "design", title: "Design"),
            LibraryTopicDefinition(id: "science", title: "Science")
        ])
        _ = try database.createDocument(
            title: "How Curiosity Becomes a Practice",
            body: """
            # How Curiosity Becomes a Practice

            Curiosity lasts when interesting ideas have somewhere to land. A personal library turns passing attention into questions you can return to.

            Save with intention, revisit what still matters, and connect each new insight to something you already know.
            """,
            texts: [
                .source: """
                # How Curiosity Becomes a Practice

                Curiosity lasts when interesting ideas have somewhere to land. A personal library turns passing attention into questions you can return to.

                Save with intention, revisit what still matters, and connect each new insight to something you already know.
                """,
                .concise: """
                # Curiosity grows through return

                Collect fewer ideas, revisit them often, and connect each new insight to something you already know.
                """,
                .detailed: """
                # The curiosity loop

                Curiosity becomes durable when it has a place to land. Capture the ideas worth returning to, group them by question, and make time to revisit what you saved.

                ## Three small habits

                Save with a purpose. Add a useful note. Return when a new idea makes the old one more interesting.
                """
            ],
            type: "link",
            sourceURL: "https://readbriefly.fyi/essays/curiosity",
            topicIDs: ["curiosity"],
            tags: ["learning", "ideas"],
            id: "fixture:article",
            captureID: "FIXTURE-ARTICLE",
            createdAt: createdAt.addingTimeInterval(240),
            addToOutbox: false
        )
        _ = try database.createDocument(
            title: "The Quiet Power of Noticing",
            body: """
            # The Quiet Power of Noticing

            Painters, scientists, and poets train the same skill: staying with a detail long enough for it to become surprising.
            """,
            texts: [
                .source: """
                # The Quiet Power of Noticing

                Painters, scientists, and poets train the same skill: staying with a detail long enough for it to become surprising.
                """,
                .concise: """
                # Attention changes what we see

                Better observation begins by slowing down, suspending the obvious answer, and looking once more.
                """,
                .detailed: """
                # Learning to notice

                Attention is not passive. It is a practice of returning to the world with fewer assumptions and better questions.

                Close observation reveals structure, exceptions, and possibilities that speed tends to hide.
                """
            ],
            type: "link",
            sourceURL: "https://readbriefly.fyi/essays/noticing",
            topicIDs: ["curiosity"],
            tags: ["attention"],
            id: "fixture:testing",
            captureID: "FIXTURE-TESTING",
            createdAt: createdAt.addingTimeInterval(180),
            addToOutbox: false
        )
        _ = try database.createDocument(
            title: "A Field Guide to Better Questions",
            body: """
            # A Field Guide to Better Questions

            The best questions open a path instead of demanding a verdict. They make room for evidence, revision, and surprise.
            """,
            texts: [
                .source: """
                # A Field Guide to Better Questions

                The best questions open a path instead of demanding a verdict. They make room for evidence, revision, and surprise.
                """,
                .concise: """
                # Ask questions that create movement

                Replace “Is this right?” with “What would change my mind?” and turn certainty into exploration.
                """,
                .detailed: """
                # Questions shape discovery

                A useful question is specific enough to guide attention and open enough to welcome an unexpected answer.
                """
            ],
            type: "link",
            sourceURL: "https://readbriefly.fyi/essays/better-questions",
            topicIDs: ["design"],
            tags: ["thinking"],
            id: "fixture:questions",
            captureID: "FIXTURE-QUESTIONS",
            createdAt: createdAt.addingTimeInterval(120),
            addToOutbox: false
        )
        _ = try database.createDocument(
            title: "Why We Remember Stories",
            body: """
            # Why We Remember Stories

            Stories give facts a shape. Sequence, tension, and emotion help an idea survive long after its details begin to fade.
            """,
            texts: [
                .source: """
                # Why We Remember Stories

                Stories give facts a shape. Sequence, tension, and emotion help an idea survive long after its details begin to fade.
                """,
                .concise: """
                # Memory follows meaning

                We remember information more easily when it becomes part of a coherent world with movement and consequence.
                """,
                .detailed: """
                # Narrative is a memory structure

                Stories connect events through cause, emotion, and expectation. That structure gives the mind more ways to find an idea again.
                """
            ],
            type: "link",
            sourceURL: "https://readbriefly.fyi/essays/stories-and-memory",
            topicIDs: ["science"],
            tags: ["memory"],
            id: "fixture:stories",
            captureID: "FIXTURE-STORIES",
            createdAt: createdAt.addingTimeInterval(60),
            addToOutbox: false
        )
        _ = try database.createDocument(
            title: "Designing a Life Around Deep Work",
            body: """
            # Designing a Life Around Deep Work

            Focus is easier when the environment carries some of the burden. Rituals, boundaries, and visible priorities protect time for difficult ideas.
            """,
            texts: [
                .source: """
                # Designing a Life Around Deep Work

                Focus is easier when the environment carries some of the burden. Rituals, boundaries, and visible priorities protect time for difficult ideas.
                """,
                .concise: """
                # Make focus the default

                Design repeatable conditions for concentration instead of negotiating with distraction every day.
                """,
                .detailed: """
                # Protect the work that needs depth

                Consistent cues, clear boundaries, and fewer open loops make sustained attention easier to begin and easier to trust.
                """
            ],
            type: "link",
            sourceURL: "https://readbriefly.fyi/essays/deep-work",
            topicIDs: ["design"],
            tags: ["focus"],
            id: "fixture:deep-work",
            captureID: "FIXTURE-DEEP-WORK",
            createdAt: createdAt,
            addToOutbox: false
        )
        try database.saveChannelRecords([
            SQLiteChannelRecord(
                source: channelSource,
                title: "Briefly Sample Feed",
                kind: .feed,
                schedule: "manual",
                lastCheckedAt: ISO8601DateFormatter().string(from: createdAt),
                reviewLimit: defaultChannelReviewLimit,
                canLoadMore: false,
                seen: [],
                items: []
            )
        ])
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
