import Foundation
import FoundationModels

/// Reports the current date and time. The on-device model has no clock, so
/// this is the smallest useful example of a tool the harness can offer.
public struct CurrentDateTool: Tool {
    public let name = "current_date"
    public let description = "Returns the current local date and time."

    @Generable
    public struct Arguments {
        @Guide(description: "IANA time zone identifier such as Europe/London. Defaults to the local zone.")
        public var timeZone: String?
    }

    public init() {}

    public func call(arguments: Arguments) async throws -> String {
        let zone = arguments.timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
        return Self.format(Date(), in: zone)
    }

    static func format(_ date: Date, in zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        return "\(formatter.string(from: date)) (\(zone.identifier))"
    }
}
