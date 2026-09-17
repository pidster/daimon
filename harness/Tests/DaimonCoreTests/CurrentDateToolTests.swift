import Foundation
import Testing

@testable import DaimonCore

@Suite struct CurrentDateToolTests {
    @Test func formatsInRequestedZone() {
        let date = Date(timeIntervalSince1970: 0)
        let out = CurrentDateTool.format(date, in: TimeZone(identifier: "Asia/Tokyo")!)
        #expect(out == "1970-01-01T09:00:00+09:00 (Asia/Tokyo)")
    }

    @Test func registrySelectsKnownAndReportsUnknown() {
        let result = ToolRegistry.select(["current_date", "nope"])
        #expect(result.tools.map(\.name) == ["current_date"])
        #expect(result.unknown == ["nope"])
    }
}
