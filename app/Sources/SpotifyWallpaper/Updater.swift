import AppKit
import CryptoKit

/// Updates the app from this repo's GitHub releases: checks the latest release, downloads its zip, verifies it
/// (GitHub's SHA-256 digest, same bundle identifier, valid code signature), swaps it into place and relaunches.
@MainActor
final class Updater {
    static let repo = "shashvat1965/spotify-wallpaper"
    private static let checkInterval: TimeInterval = 6 * 3600

    private var busy = false
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
                if userInitiated { alert("You're up to date", "Spotify Wallpaper \(currentVersion) is the latest version.") }
                return
            }
            if let problem = installProblem {
                if userInitiated { alert("Spotify Wallpaper \(release.version) is available", problem) }
                return
            }
            status = "Updating to \(release.version)…"
            try await install(release)
        } catch {
            status = nil
            if userInitiated { alert("Couldn't update", error.localizedDescription) }
            NSLog("SpotifyWallpaper: update failed: \(error)")
        }
    }

    // MARK: GitHub

    private struct Release {
        let version: String
        let asset: URL
        let sha256: String?
    }

    private func latestRelease() async throws -> Release {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("SpotifyWallpaper/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]],
              let zip = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
              let urlString = zip["browser_download_url"] as? String, let url = URL(string: urlString),
              url.scheme == "https", url.host == "github.com"
        else { throw UpdateError("The latest release doesn't have a downloadable app.") }
        let digest = (zip["digest"] as? String).flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }
        return Release(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")), asset: url, sha256: digest)
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
            return "Move Spotify Wallpaper to your Applications folder so it can update itself."
        }
        if !FileManager.default.isWritableFile(atPath: appURL.deletingLastPathComponent().path) {
            return "Spotify Wallpaper can't write to \(appURL.deletingLastPathComponent().path). Download the new version from GitHub."
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
        let zip = work.appendingPathComponent("update.zip")
        try fm.moveItem(at: download, to: zip)
        if let expected = release.sha256 {
            let actual = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
            guard actual == expected.lowercased() else { throw UpdateError("The download didn't match its checksum.") }
        }

        // unpack + verify the app
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
        guard let newApp = try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }),
              let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier
        else { throw UpdateError("The download isn't a Spotify Wallpaper app.") }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])

        // stage it next to the current app (same volume, so the final swap is a rename)
        let staged = appURL.deletingLastPathComponent().appendingPathComponent(".Spotify Wallpaper update.app")
        try? fm.removeItem(at: staged)
        try fm.moveItem(at: newApp, to: staged)

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
