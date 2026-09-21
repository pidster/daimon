import Foundation
import Testing

@testable import DaimonCore

@Suite struct FileWriterTests {
    /// A scratch directory under the temporary directory, which is inside the default writable set.
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "daimon-writer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func writesAppendsAndReplacesOnce() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = FileWriter(roots: [CommandPolicy.canonical(dir.path)])
        let file = dir.appending(path: "a.txt").path
        let created = try writer.apply(.write("one\ntwo\n"), to: file)
        #expect(created == .init(path: file, mode: "write", created: true, bytesBefore: 0, bytesAfter: 8, line: nil))
        #expect(created.rendered == "created \(file); now 8 bytes")
        let appended = try writer.apply(.append("three\n"), to: file)
        #expect(appended.created == false && appended.bytesBefore == 8 && appended.bytesAfter == 14)
        #expect(appended.rendered == "appended to \(file); now 14 bytes")
        let replaced = try writer.apply(.replace(find: "two", replacement: "2"), to: file)
        #expect(replaced.line == 2 && replaced.bytesAfter == 12)
        #expect(replaced.rendered == "replaced at line 2 of \(file); now 12 bytes")
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "one\n2\nthree\n")
        let overwritten = try writer.apply(.write("x"), to: file)
        #expect(overwritten.rendered == "wrote \(file); now 1 bytes")
        // Writes are atomic: the mode survives the rename and no temporary file is left behind.
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file)
        _ = try writer.apply(.append("y"), to: file)
        #expect(try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int == 0o640)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["a.txt"])
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "xy")
        #expect(throws: FileWriter.Failure.notFound(find: "zzz")) {
            try writer.apply(.replace(find: "zzz", replacement: ""), to: file)
        }
        try Data("ab ab".utf8).write(to: URL(fileURLWithPath: file))
        #expect(throws: FileWriter.Failure.ambiguous(find: "ab", count: 2)) {
            try writer.apply(.replace(find: "ab", replacement: "c"), to: file)
        }
        #expect(throws: FileWriter.Failure.notFound(find: "")) {
            try writer.apply(.replace(find: "", replacement: "c"), to: file)
        }
    }

    @Test func replacesANumberedLineAndChecksWhatIsThere() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = FileWriter(roots: [CommandPolicy.canonical(dir.path)])
        let file = dir.appending(path: "n.txt").path
        try Data("one\ntwo\nthree\n".utf8).write(to: URL(fileURLWithPath: file))
        let result = try writer.apply(.replaceLine(2, content: "TWO", expecting: "two"), to: file)
        #expect(result.line == 2 && result.mode == "replace" && result.bytesAfter == 14)
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "one\nTWO\nthree\n")
        // Without a check the number alone decides; the trailing newline survives; the last line counts.
        _ = try writer.apply(.replaceLine(3, content: "3", expecting: nil), to: file)
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "one\nTWO\n3\n")
        #expect(throws: FileWriter.Failure.noSuchLine(4, lines: 3)) {
            try writer.apply(.replaceLine(4, content: "x", expecting: nil), to: file)
        }
        #expect(throws: FileWriter.Failure.noSuchLine(0, lines: 3)) {
            try writer.apply(.replaceLine(0, content: "x", expecting: nil), to: file)
        }
        #expect(throws: FileWriter.Failure.lineMismatch(1, expected: "uno", actual: "one")) {
            try writer.apply(.replaceLine(1, content: "x", expecting: "uno"), to: file)
        }
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "one\nTWO\n3\n")
        // A file without a trailing newline keeps that shape.
        try Data("a\nb".utf8).write(to: URL(fileURLWithPath: file))
        _ = try writer.apply(.replaceLine(2, content: "B", expecting: "b"), to: file)
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "a\nB")
        // One trailing newline is dropped; a second line inside the content is refused.
        _ = try writer.apply(.replaceLine(1, content: "A\n", expecting: nil), to: file)
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "A\nB")
        #expect(throws: FileWriter.Failure.notOneLine(1)) {
            try writer.apply(.replaceLine(1, content: "A\nB\n", expecting: nil), to: file)
        }
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "A\nB")
        #expect(FileWriter.Failure.notOneLine(2).description == "content for line 2 must be one line; nothing changed")
        #expect(FileWriter.Failure.noSuchLine(9, lines: 2).description == "no line 9: the file has 2 lines")
        #expect(FileWriter.Failure.lineMismatch(1, expected: "x", actual: "y").description.contains("it is: y"))
        try Data([0x61, 0x00]).write(to: URL(fileURLWithPath: file))
        #expect(throws: FileWriter.Failure.binary(file)) {
            try writer.apply(.replaceLine(1, content: "x", expecting: nil), to: file)
        }
    }

    @Test func refusesOutsideTheWritableSetAndUnusablePaths() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let inside = FileWriter(roots: [CommandPolicy.canonical(dir.path)])
        let outside = FileManager.default.homeDirectoryForCurrentUser.appending(path: "daimon-must-not-exist.txt").path
        #expect(
            throws: FileWriter.Failure.outsideWritableSet(path: outside, roots: [CommandPolicy.canonical(dir.path)])
        ) {
            try inside.apply(.write("x"), to: outside)
        }
        #expect(!FileManager.default.fileExists(atPath: outside))
        // A sibling whose name merely starts with the root is outside it.
        #expect(!inside.permits(dir.path + "-sibling/x"))
        // The check follows symlinks: /tmp is /private/tmp.
        #expect(FileWriter(roots: ["/private/tmp"]).permits("/tmp/x"))
        #expect(throws: FileWriter.Failure.isDirectory(dir.path)) { try inside.apply(.write("x"), to: dir.path) }
        // A rename that cannot happen leaves no temporary file and the original untouched.
        let locked = dir.appending(path: "locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let target = locked.appending(path: "t.txt")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        #expect(throws: (any Error).self) { try inside.apply(.write("new"), to: target.path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
        #expect(try String(contentsOfFile: target.path, encoding: .utf8) == "keep")
        #expect(try FileManager.default.contentsOfDirectory(atPath: locked.path) == ["t.txt"])
        let orphan = dir.appending(path: "missing/x.txt").path
        #expect(throws: FileWriter.Failure.noParent(orphan)) { try inside.apply(.write("x"), to: orphan) }
        let binary = dir.appending(path: "b.bin").path
        try Data([0x61, 0x00, 0x62]).write(to: URL(fileURLWithPath: binary))
        #expect(throws: FileWriter.Failure.binary(binary)) {
            try inside.apply(.replace(find: "a", replacement: "b"), to: binary)
        }
        let small = FileWriter(roots: nil, maxBytes: 2)
        let big = dir.appending(path: "big.txt").path
        try Data("abc".utf8).write(to: URL(fileURLWithPath: big))
        #expect(throws: FileWriter.Failure.tooLarge(path: big, bytes: 3, limit: 2)) {
            try small.apply(.replace(find: "a", replacement: "b"), to: big)
        }
        // Unconfined when the sandbox is off; confined to the runner's roots otherwise.
        #expect(FileWriter(options: .init(policy: .unrestricted)).roots == nil)
        let confined = FileWriter(options: .init(writableRoot: dir.path))
        #expect(confined.roots?.first == CommandPolicy.canonical(dir.path))
        #expect(confined.roots?.contains("/private/tmp") == true)
        #expect(confined.permits(dir.appending(path: "new.txt").path))
        #expect(!confined.permits(outside))
        for failure: FileWriter.Failure in [
            .outsideWritableSet(path: "/p", roots: ["/r"]), .noParent("/p"), .isDirectory("/p"), .binary("/p"),
            .tooLarge(path: "/p", bytes: 2, limit: 1), .notFound(find: String(repeating: "x", count: 70) + "\nmore"),
            .ambiguous(find: "y", count: 3), .notApproved("no"),
        ] {
            #expect(!failure.description.isEmpty)
        }
        #expect(FileWriter.Failure.notFound(find: String(repeating: "x", count: 70)).description.hasSuffix("…"))
    }
}
