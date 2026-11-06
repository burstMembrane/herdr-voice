// vadwatch: prints SPEECH_START / SPEECH_END (with seconds since launch) using macOS's built-in voice activity
// detection (AVAudioEngine voice processing, macOS 14+). No model, no download. Runs for N seconds (default 20).
import AVFoundation
import Foundation

let seconds = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 20 : 20
let engine = AVAudioEngine()
let input = engine.inputNode
do { try input.setVoiceProcessingEnabled(true) } catch { print("voice processing unavailable: \(error)"); exit(2) }
input.isVoiceProcessingInputMuted = true          // muted talker detection: the app hears nothing, but the OS still reports speech
let t0 = Date()
let ok = input.setMutedSpeechActivityEventListener { event in
    let t = String(format: "%.2f", Date().timeIntervalSince(t0))
    print(event == .started ? "SPEECH_START \(t)s" : "SPEECH_END   \(t)s"); fflush(stdout)
}
print("listener installed: \(ok); say a few sentences with pauses (\(Int(seconds)) s)"); fflush(stdout)
engine.prepare()
do { try engine.start() } catch { print("engine failed: \(error)"); exit(3) }
RunLoop.main.run(until: Date().addingTimeInterval(seconds))
engine.stop()
print("done")
