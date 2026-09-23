/// Columns of plain text padded to line up in a monospaced terminal, for chat output such as `/models`
/// and `/stats`. Tabs cannot do this: a terminal's tab stops are eight cells apart and the TUI draws a
/// tab as one cell, so tab-separated columns drift. Cells are unstyled, because escape codes would count
/// towards a column's width.
public enum TextTable {
    /// Cells between columns.
    public static let gap = 2

    /// Renders `rows` under `header`, each column as wide as its widest cell.
    ///
    /// - Parameters:
    ///   - header: Column titles; the number of columns. A row with fewer cells is padded with empty ones.
    ///   - rows: The cells, one array per line.
    ///   - rightAligned: Indices of columns that pad on the left, for numbers.
    /// - Returns: One line for the header and one per row, without trailing spaces.
    public static func render(header: [String], rows: [[String]], rightAligned: Set<Int> = []) -> [String] {
        let lines = [header] + rows.map { row in (0..<header.count).map { $0 < row.count ? row[$0] : "" } }
        let widths = (0..<header.count).map { column in lines.map { $0[column].count }.max() ?? 0 }
        let spacing = String(repeating: " ", count: gap)
        return lines.map { cells in
            cells.enumerated().map { column, cell in
                let padding = String(repeating: " ", count: widths[column] - cell.count)
                return rightAligned.contains(column) ? padding + cell : cell + padding
            }
            .joined(separator: spacing)
            .replacing(/\s+$/, with: "")
        }
    }
}
