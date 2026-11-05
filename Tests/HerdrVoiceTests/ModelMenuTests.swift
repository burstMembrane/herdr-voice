import Foundation
import Testing
@testable import HerdrVoiceCore

@Test func menuListsLocalGrokGPTGeminiWithTheCurrentOneChecked() {
    let entries = ModelMenu.entries(current: .gemini, hasKey: { _ in true }, localIsBuilt: true)
    #expect(entries.map(\.title) == ["Local OpenLive", "Grok", "GPT", "Gemini", "Claude (Cloudflare)"])
    #expect(entries.map(\.checked) == [false, false, false, true, false])
    #expect(entries.allSatisfy { $0.enabled })
}

@Test func modelsWithoutAKeyAreShownButDisabled() {
    let entries = ModelMenu.entries(current: .grok, hasKey: { $0 != .openai }, localIsBuilt: true)
    #expect(entries[0] == ModelMenu.Entry(provider: .local, title: "Local OpenLive", checked: false, enabled: true))
    #expect(entries[2] == ModelMenu.Entry(provider: .openai, title: "GPT (no key)", checked: false, enabled: false))
    #expect(entries[1].enabled && entries[3].enabled)
}

@Test func localOpenLiveIsShownButDisabledUntilSetUp() {
    let built = ModelMenu.entries(current: .grok, hasKey: { _ in true }, localIsBuilt: true)
    let unbuilt = ModelMenu.entries(current: .grok, hasKey: { _ in true }, localIsBuilt: false)
    #expect(unbuilt[0] == ModelMenu.Entry(provider: .local, title: "Local OpenLive (not set up)", checked: false, enabled: false))
    #expect(Array(unbuilt.dropFirst()) == Array(built.dropFirst()))
    #expect(unbuilt.dropFirst().allSatisfy { $0.enabled })
}

@Test func localProviderNeedsNoAPIKey() {
    #expect(!Provider.local.requiresAPIKey)
    #expect(Provider.local.apiKey(environment: [:]) == nil)
    #expect(Provider.local.defaultVoice == "af_heart")
}

@Test func theConfiguredVoiceOnlyAppliesToTheProviderItNamesAVoiceOf() {
    // Started on Grok with HERDR_VOICE_VOICE=rex: Grok keeps Rex; GPT and Gemini use their own defaults,
    // since "rex" isn't one of their voices. Switching back to Grok brings Rex back.
    #expect(Provider.grok.voice(startedWith: .grok, configured: "rex") == "rex")
    #expect(Provider.openai.voice(startedWith: .grok, configured: "rex") == "marin")
    #expect(Provider.gemini.voice(startedWith: .grok, configured: "rex") == "Kore")
    #expect(Provider.grok.voice(startedWith: .grok, configured: nil) == "eve")
    #expect(Provider.gemini.voice(startedWith: .gemini, configured: "Puck") == "Puck")
    #expect(Provider.local.voice(startedWith: .local, configured: "af_bella") == "af_bella")
}

@Test func theDefaultProviderIsLocalOnceSetUpElseGrok() {
    #expect(Provider.defaultChoice(localIsBuilt: true) == .local)
    #expect(Provider.defaultChoice(localIsBuilt: false) == .grok)
}

@Test func onlyTheCloudflareProviderOffersAVoiceMenu() {
    #expect(Provider.cloudflare.voices.contains("hyperion"))
    #expect(Provider.allCases.filter { !$0.voices.isEmpty } == [.cloudflare])
}

@Test func promptLibraryListsFilesAndPutsTheRoleBeforeTheRules() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hv-prompts-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try "You are the PM.\n".write(to: dir.appendingPathComponent("pm.md"), atomically: true, encoding: .utf8)
    let env = ["HERDR_VOICE_PROMPTS_DIR": dir.path]
    #expect(PromptLibrary.names(env) == ["default", "pm"])
    PromptLibrary.current = "pm"
    defer { PromptLibrary.current = PromptLibrary.defaultName }
    let text = PromptLibrary.instructions(env, base: "RULES")
    #expect(text.hasPrefix("You are the PM."))
    #expect(text.contains("RULES"))
    PromptLibrary.current = "../etc"
    #expect(PromptLibrary.instructions(env, base: "RULES").hasPrefix("RULES"))
}
