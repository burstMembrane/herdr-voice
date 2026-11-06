// sttwatch: on-device Apple speech recognition from the mic. Prints partial results as you speak and a FINAL line when
// you pause. Vocabulary hints come from the arguments after the duration. Usage: sttwatch <seconds> [term ...]
import AVFoundation
import Speech

let seconds = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 20 : 20
let terms = Array(CommandLine.arguments.dropFirst(2))
let auth = DispatchSemaphore(value: 0)
var allowed = false
SFSpeechRecognizer.requestAuthorization { allowed = $0 == .authorized; auth.signal() }
auth.wait()
guard allowed else { print("speech recognition not allowed (System Settings > Privacy & Security > Speech Recognition)"); exit(2) }
guard let rec = SFSpeechRecognizer(locale: Locale(identifier: "en-AU")) ?? SFSpeechRecognizer(), rec.isAvailable else { print("recognizer unavailable"); exit(3) }
print("on-device supported: \(rec.supportsOnDeviceRecognition)")
let t0 = Date()
func stamp() -> String { String(format: "%5.2fs", Date().timeIntervalSince(t0)) }
let engine = AVAudioEngine()
var request = SFSpeechAudioBufferRecognitionRequest()
func newRequest() {
    request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.requiresOnDeviceRecognition = rec.supportsOnDeviceRecognition
    request.contextualStrings = terms
    request.addsPunctuation = true
    rec.recognitionTask(with: request) { result, error in
        if let r = result {
            print("\(r.isFinal ? "FINAL  " : "partial") \(stamp())  \(r.bestTranscription.formattedString)"); fflush(stdout)
            if r.isFinal { newRequest() }
        }
        if let e = error as NSError?, e.code != 216, e.code != 203 { print("error \(e.code): \(e.localizedDescription)") }
    }
}
newRequest()
let input = engine.inputNode
let format = input.outputFormat(forBus: 0)
input.installTap(onBus: 0, bufferSize: 1024, format: format) { buf, _ in request.append(buf) }
engine.prepare()
do { try engine.start() } catch { print("engine failed: \(error)"); exit(4) }
print("listening for \(Int(seconds)) s; terms: \(terms.joined(separator: ", "))"); fflush(stdout)
RunLoop.main.run(until: Date().addingTimeInterval(seconds))
request.endAudio(); engine.stop()
print("done")
