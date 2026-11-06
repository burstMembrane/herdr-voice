import Testing
@testable import HerdrVoiceCore

@Test func aSessionTheProviderEndedIsRenewedAtOnce() {
    #expect(Reconnect.delay(reason: .sessionEnded, attempt: 0, muted: false) == 0)
}




@Test func dropsBackOffUpToThirtySecondsThenGiveUp() {
    let delays = (0..<Reconnect.maxAttempts).map { Reconnect.delay(reason: .dropped, attempt: $0, muted: false) }
    #expect(delays == [1, 2, 4, 8, 16, 30, 30, 30])
    #expect(Reconnect.delay(reason: .dropped, attempt: Reconnect.maxAttempts, muted: false) == nil)
    // A session end that keeps failing to renew backs off like a drop.
    #expect(Reconnect.delay(reason: .sessionEnded, attempt: 2, muted: false) == 4)
}

@Test func whileMutedItWaitsForTheDeveloper() {
    #expect(Reconnect.delay(reason: .sessionEnded, attempt: 0, muted: true) == nil)
    #expect(Reconnect.delay(reason: .dropped, attempt: 0, muted: true) == nil)
}

@Test("routine session ends are recognized", arguments: [
    "Conversation timed out after 900.0 seconds due to inactivity",   // xAI, seen live
    "Your session hit the maximum duration of 60 minutes.",            // OpenAI
    "session_expired",
])
func sessionEndsAreRecognized(message: String) { #expect(Reconnect.isSessionEnd(message)) }

@Test("real errors are not mistaken for session ends", arguments: [
    "Invalid API key", "Rate limit exceeded", "The request timed out",
])
func realErrorsAreNot(message: String) { #expect(!Reconnect.isSessionEnd(message)) }

