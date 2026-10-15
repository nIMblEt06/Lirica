import AppKit
import CryptoKit

/// Updates the app from this repo's GitHub releases: checks the latest release, downloads its disk
/// image (or the zip older releases shipped), verifies it (GitHub's SHA-256 digest when available,
/// same bundle identifier, valid code signature), swaps it into place and relaunches.
@MainActor
final class Updater {
    static let repo = "shashvat1965/Lirica"
    private static let checkInterval: TimeInterval = 6 * 3600
    private static let retryInterval: TimeInterval = 15 * 60

    private var busy = false
    private var retry: Task<Void, Never>?
    var onStatusChange: (() -> Void)?
    private(set) var status: String? { didSet { onStatusChange?() } }

    var automatic: Bool {
        get { UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoUpdate") }
    }

    var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    func start() {
        Task {
            try? await Task.sleep(for: .seconds(20))
            await check(userInitiated: false)
        }
        Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.check(userInitiated: false) }
            }
        }
    }

    func check(userInitiated: Bool) async {
        guard !busy, automatic || userInitiated else { return }
        Trace.log("update check (\(userInitiated ? "manual" : "automatic"))")
        busy = true
        defer { busy = false }
        do {
            let release = try await latestRelease()
            guard Self.isNewer(release.version, than: currentVersion) else {
                if userInitiated { alert("You're up to date", "Lirica \(currentVersion) is the latest version.") }
                return
            }
            if let problem = installProblem {
                if userInitiated { alert("Lirica \(release.version) is available", problem) }
                return
            }
            status = "Updating to \(release.version)…"
            try await install(release)
        } catch {
            status = nil
            if userInitiated { alert("Couldn't update", error.localizedDescription) }
            NSLog("SpotifyWallpaper: update failed: \(error)")
            // Offline, or GitHub hiccuped: try again soon instead of waiting another six hours.
            if !userInitiated { scheduleRetry() }
        }
    }

    private func scheduleRetry() {
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.retryInterval))
            guard !Task.isCancelled else { return }
            await self?.check(userInitiated: false)
        }
    }

    // MARK: GitHub

    private struct Release {
        let version: String
        let asset: URL
        let sha256: String?
        var isDiskImage: Bool { asset.pathExtension.lowercased() == "dmg" }
    }

    /// The release to update to. The API is asked first because it also reports the asset's SHA-256
    /// digest — but anonymous API requests are limited to 60 per hour per IP, a budget that shared
    /// addresses (VPNs, proxies) often exhaust, so the releases page is the fallback. It has no
    /// such limit, and /releases/latest redirects to the newest tag.
    private func latestRelease() async throws -> Release {
        if let release = try? await releaseFromAPI() { return release }
        return try await releaseFromWebsite()
    }

    private func releaseFromAPI() async throws -> Release {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("SpotifyWallpaper/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]]
        else { throw UpdateError("GitHub didn't return a release.") }
        let candidates = assets.compactMap { asset -> (name: String, url: URL, sha256: String?)? in
            guard let name = asset["name"] as? String,
                  let urlString = asset["browser_download_url"] as? String,
                  let url = URL(string: urlString), url.scheme == "https", url.host == "github.com"
            else { return nil }
            let digest = (asset["digest"] as? String).flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }
            return (name, url, digest)
        }
        guard let asset = Self.preferredAsset(candidates) else {
            throw UpdateError("The latest release doesn't have a downloadable app.")
        }
        return Release(version: Self.version(fromTag: tag), asset: asset.url, sha256: asset.sha256)
    }

    private func releaseFromWebsite() async throws -> Release {
        var req = URLRequest(url: URL(string: "https://github.com/\(Self.repo)/releases/latest")!, timeoutInterval: 15)
        req.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let finalURL = response.url, finalURL.path.contains("/releases/tag/") else {
            throw UpdateError("Couldn't reach GitHub to check for updates.")
        }
        let tag = finalURL.lastPathComponent
        let version = Self.version(fromTag: tag)
        // New releases ship a disk image; the zip names are the ones older releases used.
        let names = ["Lirica-\(version).dmg", "Lirica-\(version).zip", "Spotify-Wallpaper-\(version).zip"]
        for name in names {
            guard let url = URL(string: "https://github.com/\(Self.repo)/releases/download/\(tag)/\(name)") else { continue }
            var head = URLRequest(url: url, timeoutInterval: 15)
            head.httpMethod = "HEAD"
            if let (_, resp) = try? await URLSession.shared.data(for: head),
               (resp as? HTTPURLResponse)?.statusCode == 200 {
                return Release(version: version, asset: url, sha256: nil)
            }
        }
        throw UpdateError("The latest release doesn't have a downloadable app.")
    }

    private static func preferredAsset(_ assets: [(name: String, url: URL, sha256: String?)])
        -> (name: String, url: URL, sha256: String?)? {
        assets.first { $0.name.lowercased().hasSuffix(".dmg") }
            ?? assets.first { $0.name.lowercased().hasSuffix(".zip") }
    }

    private static func version(fromTag tag: String) -> String {
        tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    // MARK: install

    private var appURL: URL { Bundle.main.bundleURL }

    /// Why the app can't replace itself, if it can't.
    private var installProblem: String? {
        if appURL.path.contains("/AppTranslocation/") || appURL.pathExtension != "app" {
            return "Move Lirica to your Applications folder so it can update itself."
        }
        if !FileManager.default.isWritableFile(atPath: appURL.deletingLastPathComponent().path) {
            return "Lirica can't write to \(appURL.deletingLastPathComponent().path). Download the new version from GitHub."
        }
        return nil
    }

    private func install(_ release: Release) async throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("SpotifyWallpaperUpdate-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // download + verify the archive
        let (download, response) = try await URLSession.shared.download(from: release.asset)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("The download failed.") }
        let file = work.appendingPathComponent(release.asset.lastPathComponent)
        try fm.moveItem(at: download, to: file)
        if let expected = release.sha256 {
            let actual = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
            guard actual == expected.lowercased() else { throw UpdateError("The download didn't match its checksum.") }
        }

        // unpack: mount the disk image, or expand the zip older releases shipped
        let unpacked: URL
        var mounted: URL?
        defer {
            if let mounted { try? run("/usr/bin/hdiutil", ["detach", mounted.path, "-quiet"]) }
        }
        if release.isDiskImage {
            let mount = work.appendingPathComponent("mnt")
            try fm.createDirectory(at: mount, withIntermediateDirectories: true)
            try run("/usr/bin/hdiutil", ["attach", file.path, "-nobrowse", "-noautoopen", "-readonly", "-mountpoint", mount.path])
            unpacked = mount
            mounted = mount
        } else {
            try run("/usr/bin/ditto", ["-x", "-k", file.path, work.path])
            unpacked = work
        }

        // verify the app
        guard let newApp = try fm.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }),
              let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier
        else { throw UpdateError("The download isn't a Lirica app.") }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])

        // stage it next to the current app (same volume, so the final swap is a rename)
        let staged = appURL.deletingLastPathComponent().appendingPathComponent(".Lirica update.app")
        try? fm.removeItem(at: staged)
        if release.isDiskImage {
            try run("/usr/bin/ditto", [newApp.path, staged.path])   // ditto keeps the signature intact
        } else {
            try fm.moveItem(at: newApp, to: staged)
        }

        // swap once this process has quit, then relaunch
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        rm -rf "$2.old"
        if mv "$2" "$2.old"; then
          if mv "$3" "$2"; then rm -rf "$2.old"; else mv "$2.old" "$2"; fi
        fi
        xattr -dr com.apple.quarantine "$2" 2>/dev/null
        open "$2"
        """
        let swap = Process()
        swap.executableURL = URL(fileURLWithPath: "/bin/sh")
        swap.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), appURL.path, staged.path]
        try swap.run()
        NSApp.terminate(nil)
    }

    private func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError("Verifying the update failed (\((tool as NSString).lastPathComponent)).") }
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
