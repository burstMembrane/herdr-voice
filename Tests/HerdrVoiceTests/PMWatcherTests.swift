import Foundation
import Testing
@testable import HerdrVoiceCore

private final class FakePM: @unchecked Sendable {
    var turn = 5, state = "done", screen = "⏺ Release is green.\n❯ \n"
    func run(_ a: [String]) -> String {
        switch a.first {
        case "ls": return #"{"terminals":[{"address":"t1g","agent":"claude-code","status":"done"}]}"#
        case "get": return a[1] == "t1g" && a.count > 2 ? #"{"title":"pm","turn":\#(turn),"status":{"state":"\#(state)","msg":""}}"# : "{}"
        case "read": return try! String(data: JSONSerialization.data(withJSONObject: ["text": screen]), encoding: .utf8)!
        default: return "{}"
        }
    }
}

@Suite(.serialized) struct PMWatcherTests {
@Test func aTurnThePMFinishesAloneIsReportedOnceAfterItSettles() {
    let pm = FakePM()
    var updates: [String] = []
    let watcher = PMWatcher(run: pm.run) { updates.append($0) }
    watcher.tick()                      // first look: remembers turn 5, reports nothing
    pm.turn = 6; pm.screen = "⏺ Watcher test one: build passed.\n❯ \n"
    watcher.tick()                      // new turn seen, waits one more tick
    #expect(updates.isEmpty)
    watcher.tick()                      // still settled on turn 6: reported
    #expect(updates.count == 1)
    #expect(updates[0].contains("build passed"))
    #expect(updates[0].contains("SKIP"))
    watcher.tick()                      // nothing new
    #expect(updates.count == 1)
}

@Test func aReplyToTheVoicesQuestionComesAtOnceAndIsNotSkippable() {
    PMWatcher.askAnswered()
    let pm = FakePM()
    var updates: [String] = []
    let watcher = PMWatcher(run: pm.run) { updates.append($0) }
    watcher.tick()                                  // remembers turn 5
    PMWatcher.askSent(minTurn: 7)
    pm.turn = 6; pm.screen = "⏺ Watcher test two: a stale monitor turn.\n"
    watcher.tick()                                  // turn 6 settles but is too early to be the answer
    #expect(updates.isEmpty)
    pm.turn = 7; pm.screen = "⏺ Watcher test three: the real answer.\n"
    watcher.tick()                                  // first settled turn at or after 7: spoken at once
    #expect(updates.count == 1)
    #expect(updates[0].contains("the real answer"))
    #expect(updates[0].contains("your own written reply is ready"))
    #expect(!updates[0].contains("SKIP"))
}

@Test func aWorkingPMIsNotReported() {
    PMWatcher.askAnswered()
    let pm = FakePM()
    var updates: [String] = []
    let watcher = PMWatcher(run: pm.run) { updates.append($0) }
    watcher.tick()
    pm.turn = 9; pm.state = "working"; pm.screen = "⏺ Watcher test four.\n"
    watcher.tick(); watcher.tick()
    #expect(updates.isEmpty)
}
}
