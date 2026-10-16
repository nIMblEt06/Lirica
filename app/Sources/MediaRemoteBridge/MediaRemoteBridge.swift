import AppKit
import Darwin
import Foundation
import ObjectiveC

/// Loaded into Apple's `/usr/bin/perl` process, which retains access to MediaRemote on macOS 15.4 and later.
private let mediaRemoteHandle = dlopen(
    "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
    RTLD_LAZY
)
private let mediaRemoteQueue = DispatchQueue(label: "com.shashvat.lirica.mediaremote")

private func mediaRemoteFunction<T>(_ name: String, as type: T.Type) -> T? {
    guard let mediaRemoteHandle, let address = dlsym(mediaRemoteHandle, name) else { return nil }
    return unsafeBitCast(address, to: type)
}

private typealias ReadClients = @convention(c) (
    DispatchQueue, @escaping @convention(block) (NSArray?) -> Void
) -> Void
private typealias ReadClient = @convention(c) (
    DispatchQueue, @escaping @convention(block) (AnyObject?) -> Void
) -> Void
private typealias ClientPID = @convention(c) (AnyObject) -> Int32
private typealias ClientString = @convention(c) (AnyObject) -> Unmanaged<CFString>?
private typealias ReadInfo = @convention(c) (
    AnyObject, Bool, DispatchQueue,
    @escaping @convention(block) (NSDictionary?, UnsafeRawPointer?) -> Void
) -> Void
private typealias ReadPlaybackState = @convention(c) (
    AnyObject, DispatchQueue, @escaping @convention(block) (UInt32) -> Void
) -> Void
private typealias CopyArtwork = @convention(c) (UnsafeRawPointer) -> Unmanaged<CFData>?
private typealias SendToPlayer = @convention(c) (
    Int32, CFDictionary?, AnyObject, UInt32, DispatchQueue,
    @escaping @convention(block) (UInt32, NSArray?) -> Void
) -> Bool

private func clients() -> [AnyObject] {
    guard let read = mediaRemoteFunction("MRMediaRemoteGetNowPlayingClients", as: ReadClients.self) else { return [] }
    let done = DispatchGroup()
    done.enter()
    var result: [AnyObject] = []
    read(mediaRemoteQueue) { value in
        result = (value as? [AnyObject]) ?? []
        done.leave()
    }
    guard done.wait(timeout: .now() + 1) == .success else { return [] }
    return result
}

private func pid(of client: AnyObject) -> Int32? {
    mediaRemoteFunction("MRNowPlayingClientGetProcessIdentifier", as: ClientPID.self)?(client)
}

private func string(_ symbol: String, from client: AnyObject) -> String {
    mediaRemoteFunction(symbol, as: ClientString.self)?(client)?.takeUnretainedValue() as String? ?? ""
}

private func stringConstant(_ symbol: String) -> String? {
    guard let mediaRemoteHandle, let address = dlsym(mediaRemoteHandle, symbol) else { return nil }
    return address.assumingMemoryBound(to: NSString?.self).pointee as String?
}

private func playerPath(for client: AnyObject) -> NSObject? {
    guard let pathClass = NSClassFromString("MRPlayerPath"),
          let shared = (pathClass as AnyObject)
            .perform(NSSelectorFromString("localPlayerPath"))?.takeUnretainedValue() as? NSObject,
          let path = shared.copy() as? NSObject else { return nil }
    path.perform(NSSelectorFromString("setClient:"), with: client)
    path.perform(NSSelectorFromString("setPlayer:"), with: nil)
    return path
}

private func currentPID() -> Int32? {
    guard let read = mediaRemoteFunction("MRMediaRemoteGetNowPlayingClient", as: ReadClient.self) else { return nil }
    let done = DispatchGroup()
    done.enter()
    var result: Int32?
    read(mediaRemoteQueue) { client in
        result = client.flatMap(pid(of:))
        done.leave()
    }
    guard done.wait(timeout: .now() + 1) == .success else { return nil }
    return result
}

private func jsonValue(_ value: Any?) -> Any? {
    switch value {
    case let number as NSNumber: return number
    case let string as String: return string
    case let date as Date: return date.timeIntervalSince1970 * 1_000_000
    default: return nil
    }
}

/// One registered player's current item. Artwork is fetched only when its item identity changes.
private func snapshot(_ client: AnyObject, artwork: Bool) -> [String: Any]? {
    guard let clientPID = pid(of: client), clientPID > 0,
          let path = playerPath(for: client),
          let readInfo = mediaRemoteFunction("MRMediaRemoteGetNowPlayingInfoForPlayer", as: ReadInfo.self),
          let readState = mediaRemoteFunction("MRMediaRemoteGetPlaybackStateForPlayer", as: ReadPlaybackState.self)
    else { return nil }

    var result: [String: Any] = [
        "processIdentifier": clientPID,
        "bundleIdentifier": string("MRNowPlayingClientGetBundleIdentifier", from: client),
        "parentBundleIdentifier": string("MRNowPlayingClientGetParentAppBundleIdentifier", from: client),
        "displayName": string("MRNowPlayingClientGetDisplayName", from: client),
    ]
    let reads = DispatchGroup()
    reads.enter()
    readInfo(path, artwork, mediaRemoteQueue) { info, artworkObject in
        let fields: [(String, String)] = [
            ("title", "kMRMediaRemoteNowPlayingInfoTitle"),
            ("artist", "kMRMediaRemoteNowPlayingInfoArtist"),
            ("album", "kMRMediaRemoteNowPlayingInfoAlbum"),
            ("artworkMimeType", "kMRMediaRemoteNowPlayingInfoArtworkMIMEType"),
            ("durationMicros", "kMRMediaRemoteNowPlayingInfoDuration"),
            ("elapsedTimeMicros", "kMRMediaRemoteNowPlayingInfoElapsedTime"),
            ("timestampEpochMicros", "kMRMediaRemoteNowPlayingInfoTimestamp"),
            ("playbackRate", "kMRMediaRemoteNowPlayingInfoPlaybackRate"),
            ("contentItemIdentifier", "kMRMediaRemoteNowPlayingInfoContentItemIdentifier"),
        ]
        for (output, input) in fields {
            guard var value = jsonValue(info?[input]) else { continue }
            if output == "durationMicros" || output == "elapsedTimeMicros" {
                value = ((value as? NSNumber)?.doubleValue ?? 0) * 1_000_000
            }
            result[output] = value
        }
        if artwork, let artworkObject,
           let copy = mediaRemoteFunction("MRNowPlayingArtworkCopyImageData", as: CopyArtwork.self),
           let data = copy(artworkObject)?.takeRetainedValue() as Data?, !data.isEmpty {
            result["artworkData"] = data.base64EncodedString()
        }
        reads.leave()
    }
    reads.enter()
    readState(path, mediaRemoteQueue) { state in
        // 1 = playing; 2 = paused; 3 = stopped; 4 = interrupted.
        if state == 1 { result["playing"] = true }
        else if (2...4).contains(state) { result["playing"] = false }
        reads.leave()
    }
    guard reads.wait(timeout: .now() + 1) == .success else { return nil }
    if result["playing"] == nil {
        result["playing"] = (result["playbackRate"] as? NSNumber)?.doubleValue ?? 0 > 0
    }
    return result
}

private func itemIdentifier(for path: AnyObject) -> String? {
    guard let read = mediaRemoteFunction("MRMediaRemoteGetNowPlayingInfoForPlayer", as: ReadInfo.self) else { return nil }
    let done = DispatchGroup()
    done.enter()
    var result: String?
    read(path, false, mediaRemoteQueue) { info, _ in
        result = info?["kMRMediaRemoteNowPlayingInfoContentItemIdentifier"] as? String
        done.leave()
    }
    guard done.wait(timeout: .now() + 1) == .success else { return nil }
    return result
}

private func identity(_ session: [String: Any]) -> String {
    if let item = session["contentItemIdentifier"] as? String, !item.isEmpty { return item }
    return ["bundleIdentifier", "title", "artist", "album"]
        .map { session[$0] as? String ?? "" }.joined(separator: "|")
}

private func emit(_ object: Any) {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

/// Streams a complete snapshot once a second. Unlike the global MediaRemote feed, this retains every registered
/// player, so a browser and Spotify can both be playing without whichever changed last hiding the other.
@_cdecl("lirica_mediaremote_stream")
public func liricaMediaRemoteStream() {
    var artworkIdentity: [Int32: String] = [:]
    while getppid() != 1 {
        var sessions: [[String: Any]] = []
        var livePIDs = Set<Int32>()
        for client in clients().prefix(20) {
            guard var session = snapshot(client, artwork: false),
                  let clientPID = (session["processIdentifier"] as? NSNumber)?.int32Value else { continue }
            livePIDs.insert(clientPID)
            let item = identity(session)
            if artworkIdentity[clientPID] != item, let withArtwork = snapshot(client, artwork: true) {
                session = withArtwork
                artworkIdentity[clientPID] = item
            }
            sessions.append(session)
        }
        artworkIdentity = artworkIdentity.filter { livePIDs.contains($0.key) }
        var message: [String: Any] = ["type": "sessions", "sessions": sessions]
        if let current = currentPID() { message["currentPID"] = current }
        emit(message)
        Thread.sleep(forTimeInterval: 1)
    }
}

/// Sends only when the requested player still owns the system session. macOS redirects an unprivileged targeted
/// command to the current player, so refusing a stale/non-current target is what guarantees controls never switch.
@_cdecl("lirica_mediaremote_send")
public func liricaMediaRemoteSend() {
    let environment = ProcessInfo.processInfo.environment
    guard let wantedPID = environment["LIRICA_MEDIAREMOTE_PID"].flatMap(Int32.init) else {
        emit(["sent": false, "reason": "invalid-target"])
        return
    }
    guard currentPID() == wantedPID else {
        emit(["sent": false, "reason": "not-current"])
        return
    }
    guard let client = clients().first(where: { pid(of: $0) == wantedPID }),
          let path = playerPath(for: client),
          let send = mediaRemoteFunction("MRMediaRemoteSendCommandToPlayer", as: SendToPlayer.self) else {
        emit(["sent": false, "reason": "unavailable"])
        return
    }
    let command: Int32
    var options: [String: Any] = [:]
    if let seconds = environment["LIRICA_MEDIAREMOTE_SEEK"].flatMap(Double.init),
       let key = stringConstant("kMRMediaRemoteOptionPlaybackPosition") {
        command = 24 // seek to an absolute playback position
        options[key] = max(0, seconds)
    } else if let requested = environment["LIRICA_MEDIAREMOTE_COMMAND"].flatMap(Int32.init) {
        command = requested
    } else {
        emit(["sent": false, "reason": "invalid-command"])
        return
    }
    if let item = itemIdentifier(for: path),
       let key = stringConstant("kMRMediaRemoteOptionNowPlayingContentItemID") {
        options[key] = item
    }
    // Reading the item took time. Recheck ownership immediately before delivery; otherwise mediaremoted can silently
    // redirect this targeted call to another app that became current in the meantime.
    guard currentPID() == wantedPID else {
        emit(["sent": false, "reason": "target-changed"])
        return
    }
    let done = DispatchGroup()
    done.enter()
    var sent = false
    let settings = options.isEmpty ? nil : options as CFDictionary
    let accepted = send(command, settings, path, 0, mediaRemoteQueue) { error, replies in
        sent = error == 0 && (replies as? [NSNumber])?.contains(where: { $0.intValue == 0 }) == true
        done.leave()
    }
    if accepted { _ = done.wait(timeout: .now() + 2) }
    emit(["sent": accepted && sent])
}
