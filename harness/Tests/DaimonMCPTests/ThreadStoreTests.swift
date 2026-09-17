import Testing

@testable import DaimonMCP

@Suite struct ThreadStoreTests {
    @Test func createsFindsAndCloses() async throws {
        let store = ThreadStore<String>(capacity: 4)
        _ = try await store.create(id: "a") { "A" }
        #expect(await store.find("a") == "A")
        #expect(await store.find("b") == nil)
        try await store.close("a")
        #expect(await store.find("a") == nil)
    }

    @Test func rejectsDuplicateAndUnknownIds() async throws {
        let store = ThreadStore<String>(capacity: 4)
        _ = try await store.create(id: "a") { "A" }
        await #expect(throws: ThreadStore<String>.Failure.alreadyExists("a")) {
            try await store.create(id: "a") { "A2" }
        }
        await #expect(throws: ThreadStore<String>.Failure.notFound("zz")) { try await store.close("zz") }
    }

    @Test func evictsLeastRecentlyUsedAtCapacity() async throws {
        let store = ThreadStore<String>(capacity: 2)
        _ = try await store.create(id: "a") { "A" }
        _ = try await store.create(id: "b") { "B" }
        _ = await store.find("a")  // b is now least recently used
        _ = try await store.create(id: "c") { "C" }
        #expect(await store.ids == ["c", "a"])
        #expect(await store.find("b") == nil)
    }

    @Test func factoryErrorsDoNotStoreAThread() async {
        struct Boom: Error {}
        let store = ThreadStore<String>(capacity: 2)
        await #expect(throws: Boom.self) { try await store.create(id: "a") { throw Boom() } }
        #expect(await store.ids.isEmpty)
    }
}
