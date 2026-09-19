import Foundation
import FoundationModels

/// Wraps a tool so every call and result is recorded in the audit log.
///
/// The model sees the wrapped tool unchanged: name, description, and schema
/// are forwarded. Arguments are logged as the JSON the model produced and the
/// output verbatim; a thrown error is logged and rethrown.
public struct AuditedTool<Base: DaimonTool>: DaimonTool {
    /// Arguments are the base tool's.
    public typealias Arguments = Base.Arguments
    /// Output is the base tool's.
    public typealias Output = String

    private let base: Base
    private let audit: AuditLog

    /// Wraps `base` to record into `audit`.
    public init(_ base: Base, audit: AuditLog) {
        self.base = base
        self.audit = audit
    }

    /// Forwarded from the base tool.
    public var name: String { base.name }
    /// Forwarded from the base tool.
    public var description: String { base.description }
    /// Forwarded from the base tool.
    public var parameters: GenerationSchema { base.parameters }
    /// Forwarded from the base tool.
    public var includesSchemaInInstructions: Bool { base.includesSchemaInInstructions }
    /// Forwarded from the base tool.
    public var limits: String { base.limits }
    /// Forwarded from the base tool.
    public var examplePrompt: String { base.examplePrompt }

    /// Records the call, invokes the base tool, records the result or error.
    ///
    /// - Throws: Whatever the base tool throws.
    public func call(arguments: Arguments) async throws -> String {
        let call = String(UUID().uuidString.prefix(8)).lowercased()
        let started = Date()
        audit.record(
            .toolCall, call: call,
            details: AuditEvent.Details.toolCall(tool: base.name, arguments: arguments.generatedContent.jsonString))
        Diagnostics.tools.debug("call \(call) \(base.name) \(arguments.generatedContent.jsonString)")
        do {
            let output = try await base.call(arguments: arguments)
            audit.record(
                .toolResult, call: call,
                details: AuditEvent.Details.toolResult(
                    tool: base.name, output: output, seconds: Date().timeIntervalSince(started)))
            return output
        } catch {
            audit.error(error, call: call, context: "tool \(base.name)")
            Diagnostics.tools.error("call \(call) \(base.name) failed: \(error)")
            throw error
        }
    }
}
