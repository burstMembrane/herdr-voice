// AppleSTT: a tiny background app that listens with Apple's on-device speech recognition and appends each finished
// sentence to ~/.config/herdr-voice/apple-stt.out as "<epoch>\t<text>". herdr-voice starts it when you pick Apple in
// the orb's Speech-to-text menu and quits it when you pick something else. It needs its own app identity because macOS
// only lets an app with a usage description ask for speech permission.
import AVFoundation
import Foundation
import Speech

let dir = NSHomeDirectory() + "/.config/herdr-voice"
let outPath = dir + "/apple-stt.out", speakingFlag = dir + "/speaking"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
let terms = ((try? String(contentsOfFile: dir + "/keyterms.txt", encoding: .utf8)) ?? "").split(whereSeparator: \.isNewline).map(String.init) + ["sheetmuse", "product manager", "PM", "Herdr", "worktree", "Claude", "Codex"]

let auth = DispatchSemaphore(value: 0); var allowed = false
SFSpeechRecognizer.requestAuthorization { allowed = $0 == .authorized; auth.signal() }
auth.wait()
guard allowed, let rec = SFSpeechRecognizer(locale: Locale(identifier: "en-AU")) ?? SFSpeechRecognizer(), rec.isAvailable else { exit(2) }

let engine = AVAudioEngine()
var request = SFSpeechAudioBufferRecognitionRequest(), task: SFSpeechRecognitionTask?
var partial = "", lastChange = Date()
func restart() {
    task?.cancel(); request.endAudio()
    request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.requiresOnDeviceRecognition = rec.supportsOnDeviceRecognition
    request.contextualStrings = terms
    request.addsPunctuation = true
    partial = ""
    task = rec.recognitionTask(with: request) { result, _ in
        guard let r = result else { return }
        let text = r.bestTranscription.formattedString
        if text != partial { partial = text; lastChange = Date() }
    }
}
func emit(_ text: String) {
    let line = "\(Int(Date().timeIntervalSince1970))\t\(text.replacingOccurrences(of: "\n", with: " "))\n"
    if let h = FileHandle(forWritingAtPath: outPath) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
    else { try? line.write(toFile: outPath, atomically: true, encoding: .utf8) }
}
restart()
engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: engine.inputNode.outputFormat(forBus: 0)) { buf, _ in
    if !FileManager.default.fileExists(atPath: speakingFlag) { request.append(buf) }    // never transcribe the voice itself
}
engine.prepare()
do { try engine.start() } catch { exit(3) }
// A sentence ends after 1.1 s without new words.
Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
    if !partial.isEmpty, Date().timeIntervalSince(lastChange) > 1.1 { emit(partial); restart() }
}
RunLoop.main.run()
