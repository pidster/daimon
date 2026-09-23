import Testing

@testable import WispCore

@Suite struct TextTableTests {
    @Test func columnsLineUpUnderTheHeader() {
        let lines = TextTable.render(
            header: ["NAME", "SIZE", "NOTE"], rows: [["a", "10", "first"], ["longer", "2", ""], ["b"]],
            rightAligned: [1])
        #expect(
            lines == [
                "NAME    SIZE  NOTE",
                "a         10  first",
                "longer     2",
                "b",
            ])
    }

    @Test func aCellWiderThanItsHeaderWidensTheColumn() {
        #expect(TextTable.render(header: ["N", "V"], rows: [["name", "x"]]) == ["N     V", "name  x"])
        #expect(TextTable.render(header: ["ONLY"], rows: []) == ["ONLY"])
    }
}
