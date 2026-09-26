import Foundation

/// A profile reduced to where the time goes: folded stacks (`frame;frame;frame count`, the format
/// `perf script | stackcollapse`, `py-spy record -f raw`, `cargo flamegraph`, and pprof's `-raw` output
/// reduce to) read without the model into the functions with the most self time and the heaviest
/// call paths ([ADR 0039](../../../../docs/decisions/0039-exact-condensers.md)).
public struct HotPaths: Sendable {
    /// A function and its share of the samples.
    public struct Frame: Equatable, Sendable {
        /// The function as the profiler named it.
        public var name: String
        /// Samples in which it was the innermost frame.
        public var selfSamples: Int
        /// Samples in which it was on the stack at all.
        public var totalSamples: Int
    }

    /// A call path and its samples.
    public struct Path: Equatable, Sendable {
        /// Frames from the outermost in.
        public var frames: [String]
        /// Samples with this exact stack.
        public var samples: Int
    }

    /// Why the profile could not be read.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// No line had the folded form.
        case notFolded

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .notFolded:
                "no folded stacks (lines of frame;frame;frame followed by a sample count); fold the profile first, "
                    + "for example with stackcollapse-perf.pl or py-spy record -f raw"
            }
        }
    }

    /// The reduced profile.
    public struct Report: Equatable, Sendable {
        /// Samples in the profile.
        public var samples: Int
        /// Distinct stacks read.
        public var stacks: Int
        /// Lines that were not folded stacks and were skipped.
        public var skipped: Int
        /// Functions with the most self time, most first.
        public var topSelf: [Frame]
        /// The heaviest stacks, most first, with frames shortened to the innermost `pathDepth`.
        public var topPaths: [Path]

        /// The report as JSON, the shape the MCP tool returns.
        public var json: JSONValue {
            .object([
                "samples": .int(samples), "stacks": .int(stacks), "skipped": .int(skipped),
                "topSelf": .array(
                    topSelf.map {
                        .object([
                            "name": .string($0.name), "self": .int($0.selfSamples), "total": .int($0.totalSamples),
                        ])
                    }),
                "topPaths": .array(
                    topPaths.map {
                        .object(["frames": .array($0.frames.map { .string($0) }), "samples": .int($0.samples)])
                    }),
            ])
        }

        /// The report as lines: self time by function, then the heaviest paths, as shares of all samples.
        public var rendered: String {
            let share = { (count: Int) in
                samples == 0 ? "0.0%" : String(format: "%.1f%%", Double(count) / Double(samples) * 100)
            }
            var lines = ["\(samples) samples in \(stacks) stacks" + (skipped > 0 ? ", \(skipped) lines skipped" : "")]
            lines.append("self time:")
            lines += topSelf.map { "  \(share($0.selfSamples))\t(total \(share($0.totalSamples)))\t\($0.name)" }
            lines.append("heaviest paths:")
            lines += topPaths.map { "  \(share($0.samples))\t\($0.frames.joined(separator: " > "))" }
            return lines.joined(separator: "\n")
        }
    }

    /// Functions to list by self time.
    public var maxFrames: Int
    /// Paths to list.
    public var maxPaths: Int
    /// Innermost frames kept per listed path.
    public var pathDepth: Int

    /// Creates a reducer.
    public init(maxFrames: Int = 15, maxPaths: Int = 8, pathDepth: Int = 6) {
        self.maxFrames = maxFrames
        self.maxPaths = maxPaths
        self.pathDepth = pathDepth
    }

    /// Reads folded stacks.
    ///
    /// - Throws: `Failure.notFolded` when no line is a folded stack.
    public func run(_ text: String) throws -> Report {
        var stacks: [String: Int] = [:]
        var skipped = 0
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let space = line.lastIndex(of: " "), let count = Int(line[line.index(after: space)...]), count > 0
            else {
                if !line.isEmpty { skipped += 1 }
                continue
            }
            // The line is trimmed, so the text before its last space is never empty.
            stacks[String(line[..<space]), default: 0] += count
        }
        guard !stacks.isEmpty else { throw Failure.notFolded }
        var selfSamples: [String: Int] = [:]
        var totalSamples: [String: Int] = [:]
        for (stack, count) in stacks {
            let frames = stack.split(separator: ";").map(String.init)
            if let leaf = frames.last { selfSamples[leaf, default: 0] += count }
            for frame in Set(frames) { totalSamples[frame, default: 0] += count }
        }
        let topSelf = selfSamples.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.prefix(maxFrames).map {
            Frame(name: $0.key, selfSamples: $0.value, totalSamples: totalSamples[$0.key] ?? $0.value)
        }
        let topPaths = stacks.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.prefix(maxPaths).map {
            Path(frames: Array($0.key.split(separator: ";").map(String.init).suffix(pathDepth)), samples: $0.value)
        }
        return Report(
            samples: stacks.values.reduce(0, +), stacks: stacks.count, skipped: skipped, topSelf: Array(topSelf),
            topPaths: Array(topPaths))
    }
}
