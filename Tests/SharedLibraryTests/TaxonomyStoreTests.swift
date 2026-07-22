import XCTest
@testable import SharedLibrary

final class TaxonomyStoreTests: XCTestCase {
    private func makeURL() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("taxonomy-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("topics.md")
    }

    func testDefaultTaxonomyRoundTripsThroughYAML() throws {
        let url = try makeURL()
        let store = TaxonomyStore()

        try store.save(TaxonomyStore.defaultTaxonomy, to: url)
        let loaded = try store.load(from: url)

        XCTAssertEqual(loaded, TaxonomyStore.defaultTaxonomy)
        XCTAssertEqual(loaded.areas.map(\.id), ["personal", "work", "learning"])
        XCTAssertEqual(loaded.topics.filter { $0.areaID == "work" }.map(\.id), [
            "product-strategy",
            "building-engineering",
            "business-operations",
            "career"
        ])
    }

    func testLegacyTopicListMigratesAndPreservesCustomTopics() throws {
        let url = try makeURL()
        try """
        # Legacy topic registry
        topics:
          - id: voice-live-building
            title: Voice Live-Building
            description: Building conversational voice products.
        """.write(to: url, atomically: true, encoding: .utf8)

        let store = TaxonomyStore()
        try store.ensureTaxonomy(at: url)
        let loaded = try store.load(from: url)
        let migrated = try XCTUnwrap(loaded.topics.first { $0.id == "voice-live-building" })

        XCTAssertEqual(migrated.areaID, "work")
        XCTAssertEqual(migrated.title, "Voice Live-Building")
        XCTAssertEqual(loaded.areas, TaxonomyStore.defaultTaxonomy.areas)
        XCTAssertTrue(loaded.topics.contains { $0.id == "self-improvement" })

        let topicCount = loaded.topics.count
        try store.ensureTaxonomy(at: url)
        XCTAssertEqual(try store.load(from: url).topics.count, topicCount)
    }

    func testDefaultsAreNotReaddedAfterUserDeletesUnusedTopic() throws {
        let url = try makeURL()
        let store = TaxonomyStore()
        var customized = TaxonomyStore.defaultTaxonomy
        customized.topics.removeAll { $0.id == "books-media" }

        try store.save(customized, to: url)
        try store.ensureTaxonomy(at: url)

        XCTAssertFalse(try store.load(from: url).topics.contains { $0.id == "books-media" })
    }

    func testTopicNamesAreReusedCaseInsensitively() throws {
        let url = try makeURL()
        let store = TaxonomyStore()
        try store.save(TaxonomyStore.defaultTaxonomy, to: url)

        let topic = try store.ensureTopic(named: "Architecture", at: url)
        let reusedTopic = try store.ensureTopic(named: "architecture", at: url)

        XCTAssertEqual(topic.id, "architecture")
        XCTAssertEqual(reusedTopic.id, topic.id)

        let loaded = try store.load(from: url)
        XCTAssertEqual(loaded.topics.filter { $0.title == "Architecture" }.count, 1)
        XCTAssertFalse(try String(contentsOf: url).contains("scope:"))
    }
}
