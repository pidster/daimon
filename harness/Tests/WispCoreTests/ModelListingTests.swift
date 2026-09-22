import Foundation
import Testing

@testable import WispCore

@Suite struct ModelListingTests {
    @Test func listsApplesModelsThenEachBackendMarkingTheCurrentOne() async {
        // Point Ollama at a port nothing listens on, so its line is the unavailable one on any Mac.
        let config = Config(ollama: .init(baseURL: "http://127.0.0.1:1", timeoutSeconds: 1)).resolved
        let home = Home(
            root: FileManager.default.temporaryDirectory.appending(path: "wisp-listing-\(UUID().uuidString)"))
        let lines = await ModelListing.lines(config: config, home: home, current: .system)
        #expect(lines.count >= 3, "\(lines)")
        #expect(lines[0].hasPrefix("* system\t"))
        #expect(lines[1].hasPrefix("  private-cloud\tunavailable: "))
        #expect(lines.contains { $0.hasPrefix("  ollama:*\tunavailable: ") })
        let other = await ModelListing.lines(config: config, home: home, current: .privateCloud)
        #expect(other[0].hasPrefix("  system\t") && other[1].hasPrefix("* private-cloud\t"))
    }
}
