import Foundation
import Testing
@testable import HerdrVoiceCore

@Test("OpenAI GA and legacy/xAI audio events decode the same", arguments: ["response.output_audio.delta", "response.audio.delta"])
func audioDeltaVariants(type: String) {
    let e = ServerEvent.decode(#"{"type":"\#(type)","item_id":"it1","delta":"AAA="}"#)
    #expect(e == .audioDelta(itemID: "it1", base64: "AAA="))
}

@Test func functionCallDecodes() {
    let e = ServerEvent.decode(#"{"type":"response.function_call_arguments.done","call_id":"c1","name":"list_agents","arguments":"{}"}"#)
    #expect(e == .functionCall(callID: "c1", name: "list_agents", arguments: "{}"))
}

@Test("short stop phrases interrupt", arguments: ["Stop.", "ok stop", "Stop talking!", "be quiet please", "Never mind.", "that's enough", "hey, shut up"])
func stopPhrasesMatch(t: String) { #expect(StopCommand.matches(t)) }

@Test("requests that mention stop are not interrupts", arguments: ["stop the dev server", "don't stop", "can you stop claude-2 from pushing", "quietly run the tests", ""])
func stopRequestsDoNotMatch(t: String) { #expect(!StopCommand.matches(t)) }

@Test func responseCreatedDecodes() {
    #expect(ServerEvent.decode(#"{"type":"response.created","response":{"id":"r1"}}"#) == .responseCreated)
}
