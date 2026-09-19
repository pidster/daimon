/// How tools render a failure for the model.
///
/// Tools return failures as text rather than throwing, because a thrown error aborts the whole
/// response with a raw framework message; the model can react to `error: …` and try another way.
public enum ToolOutput {
    /// `error: <description>`.
    public static func error(_ error: some Error) -> String {
        "error: \(error)"
    }
}
