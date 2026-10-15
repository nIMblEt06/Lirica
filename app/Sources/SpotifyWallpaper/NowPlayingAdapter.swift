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
    private let lock = NSLock()
    private var enabled = false
    private var closed = false
    private var process: Process?
    private var pipe: Pipe?
    private var buffer = Data()
    /// The merged feed: the latest value of each key, with nulls removed.
    private var state: [String: Any] = [:]
    /// The track the artwork file belongs to, and that file.
    private var artworkFor: String?
    private var artworkFile = ""
    private var restart: DispatchWorkItem?

    init?(resources: URL) {
        script = resources.appendingPathComponent("adapter/mediaremote-adapter.pl")
        framework = resources.appendingPathComponent("adapter/MediaRemoteAdapter.framework")
        guard FileManager.default.fileExists(atPath: script.path), FileManager.default.fileExists(atPath: framework.path) else {
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

    /// The track playing right now in the feed and the app playing it, or nil. Paused media isn't reported: it would
    /// stay up for good.
    func playing(now: Date) -> (track: Track, bundle: String)? {
        lock.lock()
        let s = state, artwork = artworkFor, file = artworkFile
        lock.unlock()
        guard let id = Self.trackID(s), let bundle = s["bundleIdentifier"] as? String, !Self.directlyRead.contains(bundle),
              s["playing"] as? Bool == true, let title = s["title"] as? String else { return nil }
        let rate = (s["playbackRate"] as? NSNumber)?.doubleValue ?? 1
        var position = Self.seconds(s["elapsedTimeMicros"])
        if let stamp = (s["timestampEpochMicros"] as? NSNumber)?.doubleValue {
            position += (now.timeIntervalSince1970 * 1_000_000 - stamp) / 1_000_000 * rate
        }
        let track = Track(id: id, title: title, artist: s["artist"] as? String ?? "", album: s["album"] as? String ?? "",
                          artworkURL: artwork == id ? file : "", duration: Self.seconds(s["durationMicros"]),
                          position: max(0, position), isPlaying: true)
        return (track, bundle)
    }

    /// Plays, pauses or skips: MediaRemote commands 2 (toggle), 4 (next) and 5 (previous).
    func send(_ command: Int) {
        run(["send", String(command)])
    }

    /// Seeks the playing app to `seconds`.
    func seek(_ seconds: Double) {
        run(["seek", String(Int(seconds * 1_000_000))])
    }

    private func run(_ arguments: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [script.path, framework.path] + arguments
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
        p.arguments = [script.path, framework.path, "stream", "--micros"]
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
        artworkFor = nil
        if !artworkFile.isEmpty, let url = URL(string: artworkFile) { try? FileManager.default.removeItem(at: url) }
        artworkFile = ""
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
              object["type"] as? String == "data", let diff = object["diff"] as? Bool,
              let payload = object["payload"] as? [String: Any] else { return }
        if diff {
            for (key, value) in payload { state[key] = value is NSNull ? nil : value }
        } else {
            state = payload.filter { !($0.value is NSNull) }
        }
        updateArtwork()
    }

    /// Writes a new track's cover to a temporary file once the feed has it (it can arrive a moment after the title).
    private func updateArtwork() {
        guard let id = Self.trackID(state) else {
            artworkFor = nil
            return
        }
        if artworkFor == id { return }
        guard let base64 = state["artworkData"] as? String, let data = Data(base64Encoded: base64) else {
            artworkFor = nil
            return
        }
        if !artworkFile.isEmpty, let old = URL(string: artworkFile) { try? FileManager.default.removeItem(at: old) }
        let mime = state["artworkMimeType"] as? String ?? ""
        let hash = id.utf8.reduce(UInt64(5381)) { $0 &* 33 &+ UInt64($1) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swnowplaying-\(hash).\(mime.contains("png") ? "png" : "jpg")")
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        artworkFor = id
        artworkFile = url.absoluteString
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
