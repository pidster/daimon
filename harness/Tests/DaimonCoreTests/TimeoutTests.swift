import Testing

@testable import DaimonCore

@Suite struct TimeoutTests {
    @Test func returnsResultWhenInTime() async throws {
        let value = try await withTimeout(.seconds(5)) { 42 }
        #expect(value == 42)
    }

    @Test func throwsTimeoutErrorWhenLate() async {
        await #expect(throws: TimeoutError(duration: .milliseconds(50))) {
            try await withTimeout(.milliseconds(50)) {
                try await Task.sleep(for: .seconds(10))
                return 1
            }
        }
    }

    @Test func propagatesOperationErrors() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) { try await withTimeout(.seconds(5)) { throw Boom() } }
    }

    @Test func configResolvesTimeout() {
        #expect(Config().resolved.approvalTimeout == .seconds(120))
        #expect(Config(approval: .init(timeoutSeconds: 5)).resolved.approvalTimeout == .seconds(5))
    }
}
