import Foundation

/// One voice at a time: a second copy would share the mic and hear the first one's voice.
public enum SingleInstance {
    static var path: String { NSHomeDirectory() + "/.config/herdr-voice/voice.lock" }
    private nonisolated(unsafe) static var fd: Int32 = -1

    /// Takes the lock and records this process. Returns the pid of the copy that already holds it, or nil if we got it.
    public static func acquire() -> Int32? {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 { return holder() ?? -1 }
        ftruncate(fd, 0)
        let pid = "\(getpid())\n"
        _ = pid.withCString { write(fd, $0, strlen($0)) }
        return nil
    }

    /// The pid recorded by the running copy, if any.
    public static func holder() -> Int32? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              kill(pid, 0) == 0 else { return nil }
        return pid
    }
}
