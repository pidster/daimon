import FoundationModels
import Testing

@testable import WispCore

@Suite struct ContextManagementTests {
    private func text(_ s: String) -> Transcript.Segment { .text(.init(content: s)) }
    private func prompt(_ s: String) -> Transcript.Entry { .prompt(.init(segments: [text(s)])) }
    private func response(_ s: String) -> Transcript.Entry { .response(.init(assetIDs: [], segments: [text(s)])) }
    private var instructions: Transcript.Entry {
        .instructions(.init(segments: [text("be brief")], toolDefinitions: []))
    }

    private var sample: Transcript {
        Transcript(entries: [
            instructions,
            prompt("p1"), response("r1"),
            prompt("p2"), response("r2"),
            prompt("p3"), response("r3"),
        ])
    }

    @Test func countsTurns() {
        #expect(sample.turnCount == 3)
        #expect(Transcript(entries: [instructions]).turnCount == 0)
    }

    @Test func keepsInstructionsAndLastTurns() {
        let sample = sample
        let condensed = sample.condensed(keepTurns: 2)
        #expect(condensed.count == 5)
        guard case .instructions = condensed[condensed.startIndex] else { Issue.record("instructions dropped"); return }
        #expect(condensed.turnCount == 2)
        #expect(condensed.map(\.id) == [sample[0], sample[3], sample[4], sample[5], sample[6]].map(\.id))
    }

    @Test func zeroTurnsLeavesOnlyInstructions() {
        let condensed = sample.condensed(keepTurns: 0)
        #expect(condensed.count == 1)
        #expect(Transcript(entries: [prompt("x")]).condensed(keepTurns: 0).isEmpty)
    }

    @Test func keepingMoreThanExistsIsIdentity() {
        let sample = sample
        #expect(sample.condensed(keepTurns: 10).map(\.id) == sample.map(\.id))
    }

    @Test func toolActivityStaysWithItsTurn() {
        let call = Transcript.Entry.toolCalls(.init([]))
        let transcript = Transcript(entries: [
            instructions, prompt("p1"), call, response("r1"), prompt("p2"), response("r2"),
        ])
        let condensed = transcript.condensed(keepTurns: 1)
        #expect(condensed.map(\.id) == [transcript[0], transcript[4], transcript[5]].map(\.id))
        let keepTwo = transcript.condensed(keepTurns: 2)
        #expect(keepTwo.map(\.id) == transcript.map(\.id))
    }
}
