import AppKit

/// Diagnostics for things that change other apps' windows or focus. Off unless you turn it on:
///   defaults write com.shashvat.spotifywallpaper traceEvents -bool true
/// Events are appended with timestamps to ~/Library/Logs/Spotify Wallpaper/events.log.
@MainActor
enum Trace {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "traceEvents") }

    private static let file: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Spotify Wallpaper")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("events.log")
    }()

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message())\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: file)
        }
    }

    /// Logs which app comes to the front, since a wallpaper that takes focus is the usual suspect.
    static func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                let app = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.localizedName ?? "?"
                log("front app: \(app)")
            }
        }
    }
}
