import Foundation
import Testing

@testable import DaimonCore

@Suite struct FileReaderTests {
    private func temporaryFile(_ contents: String) throws -> String {
        let url = FileManager.default.temporaryDirectory.appending(path: "daimon-fr-\(UUID().uuidString).txt")
        try Data(contents.utf8).write(to: url)
        return url.path
    }

    @Test func readsWholeSmallFile() throws {
        let path = try temporaryFile("a\nb\nc\n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let window = try FileReader().read(path: path)
        #expect(window == .init(firstLine: 1, lines: ["a", "b", "c"], hasMore: false, truncatedByBytes: false))
        #expect(window.rendered == "1\ta\n2\tb\n3\tc\n[end of file]")
    }

    @Test func pagesByOffsetAndLimit() throws {
        let path = try temporaryFile((1...10).map(String.init).joined(separator: "\n"))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let first = try FileReader().read(path: path, offset: 1, limit: 4)
        #expect(first.lines == ["1", "2", "3", "4"])
        #expect(first.nextOffset == 5)
        let last = try FileReader().read(path: path, offset: 9, limit: 4)
        #expect(last.lines == ["9", "10"])
        #expect(last.nextOffset == nil)
        let beyond = try FileReader().read(path: path, offset: 50)
        #expect(beyond.lines.isEmpty)
        #expect(beyond.rendered.contains("(no lines in range)"))
    }

    @Test func honoursByteBudget() throws {
        let path = try temporaryFile("aaaa\nbbbb\ncccc\n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let window = try FileReader(maxBytes: 9).read(path: path)
        #expect(window.lines == ["aaaa", "bbbb"])
        #expect(window.truncatedByBytes)
        #expect(window.nextOffset == 3)
    }

    @Test func streamsAcrossChunkBoundariesAndHandlesCRLF() throws {
        let path = try temporaryFile("one\r\ntwo\r\nthree")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let window = try FileReader(chunkSize: 4).read(path: path)
        #expect(window.lines == ["one", "two", "three"])
        #expect(!window.hasMore)
    }

    @Test func stopsReadingOnceWindowIsFull() throws {
        let path = try temporaryFile(String(repeating: "x\n", count: 100_000))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let window = try FileReader(chunkSize: 1024).read(path: path, offset: 10, limit: 2)
        #expect(window == .init(firstLine: 10, lines: ["x", "x"], hasMore: true, truncatedByBytes: false))
    }

    @Test func rejectsBadInputs() throws {
        let directory = FileManager.default.temporaryDirectory.path
        #expect(throws: FileReader.Failure.isDirectory(directory)) { try FileReader().read(path: directory) }
        #expect(throws: FileReader.Failure.notFound("/nonexistent/x")) { try FileReader().read(path: "/nonexistent/x") }
        let binary = try temporaryFile("ab\u{0}cd")
        defer { try? FileManager.default.removeItem(atPath: binary) }
        #expect(throws: FileReader.Failure.binary(binary)) { try FileReader().read(path: binary) }
        #expect(throws: FileReader.Failure.invalidRange) { try FileReader().read(path: binary, offset: 0) }
    }

    @Test func lineScannerSplitsAcrossFeeds() {
        var scanner = LineScanner()
        #expect(scanner.feed(Data("ab".utf8)).isEmpty)
        #expect(scanner.feed(Data("c\nd\ne".utf8)) == [Data("abc".utf8), Data("d".utf8)])
        #expect(scanner.finish() == Data("e".utf8))
        #expect(scanner.finish() == nil)
    }
}
