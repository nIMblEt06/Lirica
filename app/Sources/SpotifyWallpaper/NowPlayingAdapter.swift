import Foundation

/// Reads whatever is playing on the Mac (browsers, YouTube, any player) from the system's Now Playing feed.
///
/// Since macOS 15.4 that feed only answers apps Apple has entitled. The mediaremote-adapter helper (BSD-3-Clause,
/// github.com/ungive/mediaremote-adapter, bundled in Resources/adapter) runs inside /usr/bin/perl, which is entitled,
/// and streams the feed as JSON. Apple can close this with any macOS update; if it does, this source simply goes
/// quiet and Spotify and Music keep working.
final class NowPlayingAdapter: @unchecked Sendable {
    /// Players read directly over AppleScript; the feed repeats them, so they're skipped here.
    static let directlyRead: Set<String> = ["com.spotify.client", "com.apple.Music"]

    private let script: URL
    private let framework: URL
    private let bridgeScript: URL
    private let bridgeLibrary: URL
    private let hasBridge: Bool
    private let lock = NSLock()
    private var enabled = false
    private var closed = false
    private var process: Process?
    private var pipe: Pipe?
    private var buffer = Data()
    /// The merged feed: the latest value of each key, with nulls removed.
    private var state: [String: Any] = [:]
    /// Per-player snapshots from Lirica's bridge. The system's ordinary feed exposes only one of these at a time.
    private var sessionStates: [Int32: [String: Any]] = [:]
    private var currentPID: Int32?
    /// Per-player artwork, retained when an unchanged snapshot omits its bytes.
    private var artwork: [Int32: (trackID: String, file: String)] = [:]
    private var restart: DispatchWorkItem?

    init?(resources: URL) {
        script = resources.appendingPathComponent("adapter/mediaremote-adapter.pl")
        framework = resources.appendingPathComponent("adapter/MediaRemoteAdapter.framework")
        bridgeScript = resources.appendingPathComponent("adapter/lirica-mediaremote.pl")
        bridgeLibrary = resources.appendingPathComponent("adapter/libLiricaMediaRemoteBridge.dylib")
        let fm = FileManager.default
        hasBridge = fm.fileExists(atPath: bridgeScript.path) && fm.fileExists(atPath: bridgeLibrary.path)
        let hasLegacy = fm.fileExists(atPath: script.path) && fm.fileExists(atPath: framework.path)
        guard hasBridge || hasLegacy else {
            return nil
        }
    }

    /// Starts or stops the feed. Turning it off drops the state, so nothing stale shows later.
    func setEnabled(_ on: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard on != enabled, !closed else { return }
        enabled = on
        if on { launchLocked() } else { stopLocked() }
    }

    /// Stops the helper for good, when the app quits. Otherwise it would outlive the app.
    func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        enabled = false
        stopLocked()
    }

    struct Feed {
        let track: Track
        /// The application users configure. For a browser helper/PWA this is its parent browser when available.
        let bundle: String
        /// MediaRemote's immediate client identity, retained so dedicated YouTube Music wrappers can be recognized.
        let sourceBundle: String
        let name: String
        let pid: Int32
        let isCurrent: Bool
    }

    /// Every non-Spotify/non-Music player registered with MediaRemote. Paused tracks count, like paused Spotify,
    /// and remain independently visible even when another app becomes the system's global Now Playing player.
    func sessions(now: Date) -> [Feed] {
        lock.lock()
        let snapshots = sessionStates
        let legacy = state
        let selected = currentPID
        let covers = artwork
        lock.unlock()

        if hasBridge {
            return snapshots.compactMap { pid, snapshot in
                Self.feed(snapshot, pid: pid, currentPID: selected, artwork: covers[pid], now: now)
            }
        }
        return Self.feed(legacy, pid: 0, currentPID: 0, artwork: covers[0], now: now).map { [$0] } ?? []
    }

    private static func feed(_ s: [String: Any], pid: Int32, currentPID: Int32?,
                             artwork: (trackID: String, file: String)?, now: Date) -> Feed? {
        let ownBundle = s["bundleIdentifier"] as? String ?? ""
        let parent = s["parentBundleIdentifier"] as? String ?? ""
        let bundle = parent.isEmpty ? ownBundle : parent
        guard let id = trackID(s), !directlyRead.contains(bundle), let title = s["title"] as? String else { return nil }
        let playing = s["playing"] as? Bool == true
        let rate = (s["playbackRate"] as? NSNumber)?.doubleValue ?? 1
        var position = Self.seconds(s["elapsedTimeMicros"])
        if playing, let stamp = (s["timestampEpochMicros"] as? NSNumber)?.doubleValue {
            position += (now.timeIntervalSince1970 * 1_000_000 - stamp) / 1_000_000 * rate
        }
        let track = Track(id: id, title: title, artist: s["artist"] as? String ?? "", album: s["album"] as? String ?? "",
                          artworkURL: artwork?.trackID == id ? artwork?.file ?? "" : "",
                          duration: Self.seconds(s["durationMicros"]),
                          position: max(0, position), isPlaying: playing)
        return Feed(track: track, bundle: bundle, sourceBundle: ownBundle,
                    name: s["displayName"] as? String ?? "", pid: pid, isCurrent: pid == currentPID)
    }

    /// Plays, pauses or skips: MediaRemote commands 2 (toggle), 4 (next) and 5 (previous).
    func send(_ command: Int, to pid: Int32) {
        if hasBridge { runBridge(["send", String(pid), String(command)]) }
        else { runLegacy(["send", String(command)]) }
    }

    /// Seeks the playing app to `seconds`.
    func seek(_ seconds: Double, to pid: Int32) {
        if hasBridge { runBridge(["seek", String(pid), String(seconds)]) }
        else { runLegacy(["seek", String(Int(seconds * 1_000_000))]) }
    }

    private func runLegacy(_ arguments: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [script.path, framework.path] + arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    private func runBridge(_ arguments: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [bridgeScript.path, bridgeLibrary.path] + arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    // MARK: the stream

    private func launchLocked() {
        restart?.cancel()
        restart = nil
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = hasBridge
            ? [bridgeScript.path, bridgeLibrary.path, "stream"]
            : [script.path, framework.path, "stream", "--micros"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { self?.consume(data) }
        }
        p.terminationHandler = { [weak self] _ in self?.exited() }
        do { try p.run() } catch { return }
        process = p
        pipe = out
    }

    private func stopLocked() {
        restart?.cancel()
        restart = nil
        pipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        process?.terminate()
        clearLocked()
    }

    private func clearLocked() {
        process = nil
        pipe = nil
        buffer = Data()
        resetFeedLocked()
    }

    private func resetFeedLocked() {
        state = [:]
        sessionStates = [:]
        currentPID = nil
        for cover in artwork.values {
            if let url = URL(string: cover.file) { try? FileManager.default.removeItem(at: url) }
        }
        artwork = [:]
    }

    /// The helper quit (macOS may have closed the feed): try again in a while, while still enabled.
    private func exited() {
        lock.lock()
        defer { lock.unlock() }
        clearLocked()
        guard enabled else { return }
        let work = DispatchWorkItem { [weak self] in self?.relaunch() }
        restart = work
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: work)
    }

    private func relaunch() {
        lock.lock()
        defer { lock.unlock() }
        guard enabled, process == nil else { return }
        launchLocked()
    }

    private func consume(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            apply(line)
        }
    }

    /// One line of the stream: `{"type":"data","diff":bool,"payload":{…}}`. A diff only carries changed keys;
    /// a null key has gone away.
    private func apply(_ line: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = object["type"] as? String else { return }
        if type == "sessions", let sessions = object["sessions"] as? [[String: Any]] {
            var next: [Int32: [String: Any]] = [:]
            for session in sessions {
                guard let pid = (session["processIdentifier"] as? NSNumber)?.int32Value else { continue }
                next[pid] = session
                updateArtwork(session, pid: pid)
            }
            for pid in Set(sessionStates.keys).subtracting(next.keys) { removeArtwork(pid) }
            sessionStates = next
            currentPID = (object["currentPID"] as? NSNumber)?.int32Value
            return
        }
        guard type == "data", let diff = object["diff"] as? Bool,
              let payload = object["payload"] as? [String: Any] else { return }
        if diff {
            for (key, value) in payload { state[key] = value is NSNull ? nil : value }
        } else {
            state = payload.filter { !($0.value is NSNull) }
        }
        updateArtwork(state, pid: 0)
    }

    /// Writes a new track's cover to a temporary file once the feed has it (it can arrive a moment after the title).
    private func updateArtwork(_ state: [String: Any], pid: Int32) {
        guard let id = Self.trackID(state) else { removeArtwork(pid); return }
        if artwork[pid]?.trackID == id { return }
        removeArtwork(pid)
        guard let base64 = state["artworkData"] as? String, let data = Data(base64Encoded: base64) else { return }
        let mime = state["artworkMimeType"] as? String ?? ""
        let hash = id.utf8.reduce(UInt64(5381)) { $0 &* 33 &+ UInt64($1) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swnowplaying-\(pid)-\(hash).\(mime.contains("png") ? "png" : "jpg")")
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        artwork[pid] = (id, url.absoluteString)
    }

    private func removeArtwork(_ pid: Int32) {
        if let file = artwork.removeValue(forKey: pid)?.file, let url = URL(string: file) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: helpers

    /// Identifies a track: the same song keeps its id while its position changes.
    private static func trackID(_ s: [String: Any]) -> String? {
        guard let title = s["title"] as? String, !title.isEmpty, let bundle = s["bundleIdentifier"] as? String else { return nil }
        return [bundle, title, s["artist"] as? String ?? "", s["album"] as? String ?? ""].joined(separator: "|")
    }

    private static func seconds(_ micros: Any?) -> Double {
        ((micros as? NSNumber)?.doubleValue ?? 0) / 1_000_000
    }
}
