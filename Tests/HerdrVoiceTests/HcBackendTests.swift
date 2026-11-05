import Foundation
import Testing
@testable import HerdrVoiceCore

private let lsJSON = #"{"terminals":[{"address":"t1g","agent":"claude-code","status":"done","where":"sheetmuse-mcp / 1"},{"address":"t2b","agent":"claude-code","status":"working","name":"import-queue-ios","where":"sheetmuse-mcp / 1"},{"address":"t2g","agent":"zsh"}]}"#

private func hcCall(_ name: String, _ args: String, reply: String, userInitiated: Bool = true) -> (HerdrTools.Outcome, [[String]]) {
    var seen: [[String]] = []
    let outcome = HerdrTools.call(name, arguments: args, run: { a in
        seen.append(a)
        if a.first == "ls" { return lsJSON }
        if a.first == "get" { return a[1] == "t1g" ? #"{"title":"Sheetmuse product manager","status":{"msg":"waiting on you","state":"done"}}"# : #"{"title":"","status":{"msg":"editing","state":"working"}}"# }
        return reply }, 
                                  gate: ConfirmGate(), userInitiated: userInitiated, backend: .hc)
    return (outcome, seen)
}

@Test func hcListsOnlyAgentsWithTheirTitleAndName() {
    let (outcome, _) = hcCall("list_agents", "{}", reply: "")
    #expect(outcome.output.contains(#""target":"import-queue-ios""#))
    #expect(outcome.output.contains("Sheetmuse product manager"))
    #expect(!outcome.output.contains("zsh"))
}

@Test func hcResolvesWhatWasSaidToTheClosestAgent() {
    let (outcome, seen) = hcCall("read_agent", #"{"target":"sheep muse product manager"}"#, reply: #"{"text":"ok"}"#)
    #expect(seen.contains(["read", "t1g", "--lines", "60", "--json"]))
    #expect(outcome.output.contains("ok"))
    let (queue, _) = hcCall("prompt_agent", #"{"target":"import queue ios","text":"hi"}"#, reply: "{}")
    #expect(queue.watch == "import-queue-ios")
}

@Test func hcSaysSoWhenNothingMatches() {
    let (outcome, _) = hcCall("read_agent", #"{"target":"banana"}"#, reply: "")
    #expect(outcome.output.hasPrefix("error: no agent matches"))
}

@Test func hcPromptSendsTextAndWatchesTheAgent() {
    let (outcome, seen) = hcCall("prompt_agent", #"{"target":"import-queue-ios","text":"run the tests"}"#, reply: #"{"started":null,"status":null,"turn":1}"#)
    #expect(seen.last == ["send", "import-queue-ios", "[Liam, speaking by voice] run the tests", "--json"])
    #expect(outcome.watch == "import-queue-ios")
}

@Test func hcErrorsAreReportedNotWatched() {
    let (outcome, _) = hcCall("prompt_agent", #"{"target":"x","text":"hi"}"#, reply: #"{"error":{"message":"no terminal \"x\""}}"#)
    #expect(outcome.output.hasPrefix("error: no agent matches"))
    #expect(outcome.watch == nil)
}

@Test func hcReadCondensesAndFencesTheScreen() {
    let (outcome, seen) = hcCall("read_agent", #"{"target":"import-queue-ios","lines":5}"#, reply: #"{"text":"──────\nBuild passed\n"}"#)
    #expect(seen.contains { $0.prefix(2) == ["read", "import-queue-ios"] })
    #expect(outcome.output.contains("Build passed"))
    #expect(outcome.output.contains("UNTRUSTED"))
}

@Test func hcUnmappedToolsSayTheyAreUnavailable() {
    let (outcome, seen) = hcCall("create_worktree", #"{"name":"x"}"#, reply: "")
    #expect(seen.isEmpty)
    #expect(outcome.output.contains("not available"))
}

@Test func lastReplyTakesTheFinalAnswerBlockOnly() {
    let screen = "❯ question\n⏺ old answer\n✻ Churned for 3s\n⏺ The shipping agent is waiting.\n  Nothing needs you.\n✻ Baked for 2s\n❯ \n"
    #expect(HerdrTools.lastReply(screen) == "The shipping agent is waiting. Nothing needs you.")
    #expect(HerdrTools.lastReply("no marker here") == nil)
}
