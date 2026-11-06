import Foundation
import Testing
@testable import HerdrVoiceCore





@Test func aMissingKeychainItemIsNilAndSilent() {
    #expect(Keychain.password(service: "herdr-voice-test-\(UUID().uuidString)") == nil)
}
