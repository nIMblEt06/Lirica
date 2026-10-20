import AppKit
import Carbon.HIToolbox
import ServiceManagement

private extension Double {
    func rounded(toPlaces p: Int) -> Double {
        let m = pow(10, Double(p))
        return (self * m).rounded() / m
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let paths = Paths()
    private lazy var store = TemplateStore(paths: paths)
    private lazy var engine = Engine(store: store, paths: paths)
    private var statusItem: NSStatusItem!
    private var home: HomeWindowController?
    private lazy var thumbs = ThumbnailService(engine: engine, store: store, paths: paths)
    private var builder: BuilderWindowController?
    private var whatsNew: WhatsNewWindowController?
    private let updater = Updater()
    private lazy var history = HistoryStore(paths: paths)
    private lazy var shareCard = ShareCard(engine: engine, store: store)
    private let focusMonitor = FocusMonitor()
    private lazy var installer = TemplateInstaller(store: store, paths: paths)
    /// Focus Mode switched on by hand (not remembered across launches).
    private var manualFocus = false
    /// .swtemplate files / install links that arrived before launch finished.
    private var pendingOpen: [URL]? = []
    private var quickSwitcher: QuickSwitcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Trace.start()
        if let probe = LyricsProbe.request {
            Task { await LyricsProbe.run(probe, paths: paths) }
            return
        }
        if let dir = Screenshots.outputDir {
            Task { await Screenshots.run(to: dir, engine: engine, store: store, paths: paths) }
            return
        }
        installEditMenu()
        handleTermination()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Lirica")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        engine.onStateChange = { [weak self] in self?.home?.pushState(); self?.builder?.pushState() }
        engine.onClock = { [weak self] clock in self?.home?.pushClock(clock); self?.builder?.pushClock(clock) }
        engine.onTemplateFilesChanged = { [weak self] in self?.thumbs.invalidateAll(); self?.home?.templateFilesChanged() }
        engine.onMusicSourcesChanged = { [weak self] in self?.home?.pushState() }
        setUpAppFeatures()
        engine.start()
        updater.start()

        if WhatsNewWindowController.shouldShowAfterUpdate() { openWhatsNew() }
        if !UserDefaults.standard.bool(forKey: "launchedBefore") {
            UserDefaults.standard.set(true, forKey: "launchedBefore")
            openHome()
        }
        let queued = pendingOpen ?? []
        pendingOpen = nil
        queued.forEach { installer.open($0) }
    }

    // MARK: history, lyric cards, focus, template sharing

    private func setUpAppFeatures() {
        engine.onStillRendered = { [weak self] jpeg, _, track, templateID in
            guard let self, !self.engine.focus else { return }  // no history while lyrics are hidden
            self.history.record(jpeg, track: track, templateID: templateID,
                                colors: self.engine.statePayload(for: nil)["colors"] as? [String: Any] ?? [:])
        }
        history.onChange = { [weak self] in self?.home?.historyChanged() }
        focusMonitor.onChange = { [weak self] _ in self?.updateFocus() }
        if hideLyricsWhileSharing { focusMonitor.start() }
        installer.onInstalled = { [weak self] id in
            guard let self else { return }
            self.openHome()
            self.home?.showTemplate(id)
        }
        // Home: thumbnails for every template, and refresh when a screen's template changes from anywhere
        let thumbs = self.thumbs
        engine.schemeHandler.thumbnail = { id in await thumbs.image(for: id) }
        let previousActiveChanged = store.onActiveChanged
        store.onActiveChanged = { [weak self] in previousActiveChanged?(); self?.home?.activeChanged() }
        HotKeys.shared.register(kVK_ANSI_L) { [weak self] in self?.shareCard.share() }
        HotKeys.shared.register(kVK_ANSI_F) { [weak self] in self?.toggleFocusMode() }
        HotKeys.shared.register(kVK_ANSI_W) { [weak self] in self?.toggleQuickSwitcher() }
    }

    /// Double-clicked .swtemplate files and spotify-wallpaper://install?url=… links.
    func application(_ application: NSApplication, open urls: [URL]) {
        if pendingOpen != nil { pendingOpen?.append(contentsOf: urls) } else { urls.forEach { installer.open($0) } }
    }

    private var hideLyricsWhileSharing: Bool {
        get { UserDefaults.standard.object(forKey: "hideLyricsWhileSharing") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "hideLyricsWhileSharing") }
    }

    private func updateFocus() {
        engine.focus = manualFocus || (hideLyricsWhileSharing && focusMonitor.sharing)
    }

    @objc private func toggleFocusMode() {
        manualFocus.toggle()
        updateFocus()
        HUD.show(title: manualFocus ? "Focus Mode on" : "Focus Mode off",
                 detail: manualFocus ? "Lyrics are hidden until you turn it off (⌃⌥⌘F)." : nil)
    }

    @objc private func toggleHideWhileSharing() {
        hideLyricsWhileSharing.toggle()
        if hideLyricsWhileSharing { focusMonitor.start() } else { focusMonitor.stop() }
        updateFocus()
    }

    @objc private func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    @objc private func shareLyricCard() { shareCard.share() }

    @objc private func openHistory() {
        openHome()
        home?.show(tab: "history")
    }

    @objc private func clearHistory() {
        history.load()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Clear your wallpaper history?"
        alert.informativeText = "This deletes all \(history.entries.count) saved wallpapers from the History Wall. It can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { history.clear() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if Screenshots.outputDir == nil { engine.shutdown() }
    }

    /// `kill`/`pkill` skip applicationWillTerminate; route them through a normal quit so the wallpaper is restored.
    private var signalSources: [DispatchSourceSignal] = []
    private func handleTermination() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    // Re-opening the app from Finder/Spotlight/the Dock while it's running opens Home.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openHome()
        return false
    }

    // MARK: menu

    /// Everyday actions only; everything app-wide is in Home's Settings tab.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let playing = NSMenuItem(title: engine.nowPlayingText, action: nil, keyEquivalent: "")
        playing.isEnabled = false
        menu.addItem(playing)
        if hideLyricsWhileSharing && focusMonitor.sharing {
            let note = NSMenuItem(title: "Lyrics hidden: \(focusMonitor.reason) is sharing your screen", action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }
        menu.addItem(.separator())

        let ctrlOptCmd: NSEvent.ModifierFlags = [.control, .option, .command]
        add(menu, "Open Lirica…", #selector(openHome), "o")
        add(menu, "Quick Switcher…", #selector(toggleQuickSwitcher), "w").keyEquivalentModifierMask = ctrlOptCmd
        menu.addItem(.separator())
        let share = add(menu, "Share Lyric Card", #selector(shareLyricCard), "l")
        share.keyEquivalentModifierMask = ctrlOptCmd
        share.isEnabled = engine.track != nil
        let focus = add(menu, "Focus Mode", #selector(toggleFocusMode), "f")
        focus.keyEquivalentModifierMask = ctrlOptCmd
        focus.state = manualFocus ? .on : .off
        add(menu, engine.paused ? "Resume Wallpaper" : "Pause Wallpaper", #selector(togglePause), "")
        menu.addItem(.separator())
        if let status = updater.status {
            let note = NSMenuItem(title: status, action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }
        add(menu, "Settings…", #selector(openSettingsTab), ",")
        add(menu, "Quit Lirica", #selector(quit), "q")
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func openWhatsNew() {
        if whatsNew == nil { whatsNew = WhatsNewWindowController(engine: engine) }
        whatsNew?.show()
    }

    @objc private func checkForUpdates() { Task { await updater.check(userInitiated: true) } }

    @objc private func openLyricsTab() {
        openHome()
        home?.show(tab: "lyrics")
    }

    /// Home: the app's main window (it replaced Customize).
    @objc private func openHome() {
        if home == nil {
            home = HomeWindowController(engine: engine, store: store, paths: paths, thumbs: thumbs, history: history)
            home?.onOpenBuilder = { [weak self] id in self?.openBuilder(id) }
            home?.onShareCard = { [weak self] in self?.shareCard.share() }
            home?.installer = installer
            home?.settings = { [weak self] in self?.settingsSnapshot() ?? [:] }
            home?.onSetting = { [weak self] key, value in self?.applySetting(key, value) }
            home?.onSettingAction = { [weak self] action in self?.settingAction(action) }
            updater.onStatusChange = { [weak self] in self?.home?.pushState() }
        }
        home?.show()
    }

    @objc private func newBuilderTemplate() { openBuilder(nil) }

    /// Opens the Template Builder on a Builder template, or on a new design when `id` is nil.
    func openBuilder(_ id: String?) {
        if let b = builder, b.window?.isVisible == true, b.templateID == id, id != nil {
            b.show()
            return
        }
        builder?.close()
        builder = BuilderWindowController(engine: engine, store: store, templateID: id)
        builder?.onSaved = { [weak self] in self?.home?.sendInit() }
        builder?.show()
    }

    @objc private func togglePause() { engine.paused.toggle() }

    @objc private func openTemplatesFolder() { NSWorkspace.shared.open(paths.userTemplates) }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nMove the app to /Applications and try again."
            alert.runModal()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    /// Menu-bar apps have no main menu, which breaks ⌘C/⌘V/⌘A in text fields. Give them one.
    private func installEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit Lirica", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }
}

// MARK: - Quick Switcher (⌃⌥⌘W)

extension AppDelegate {
    @objc fileprivate func toggleQuickSwitcher() {
        if quickSwitcher == nil {
            let qs = QuickSwitcher(engine: engine, store: store)
            qs.onShareCard = { [weak self] in self?.shareCard.share() }
            qs.onToggleFocus = { [weak self] in self?.toggleFocusMode() }
            qs.isFocusOn = { [weak self] in self?.manualFocus ?? false }
            qs.onOpenHistory = { [weak self] in self?.openHistory() }
            // Home (other stream) replaces this: open the main window on that template
            qs.onOpenHome = { [weak self] id in
                self?.openHome()
                if let id { self?.home?.showTemplate(id) }
            }
            quickSwitcher = qs
        }
        quickSwitcher?.toggle()
    }
}

// MARK: - Settings (Home's Settings tab)

extension AppDelegate {
    @objc fileprivate func openSettingsTab() {
        openHome()
        home?.show(tab: "settings")
    }

    fileprivate func settingsSnapshot() -> [String: Any] {
        [
            "launchAtLogin": SMAppService.mainApp.status == .enabled,
            "paused": engine.paused,
            "refreshRate": engine.refreshRate,
            "focus": manualFocus,
            "hideWhileSharing": hideLyricsWhileSharing,
            "canReadTitles": FocusMonitor.canReadTitles,
            "sharingNow": focusMonitor.sharing ? focusMonitor.reason : "",
            "useWeather": engine.useWeather,
            "beatSync": engine.beatSync,
            "musicPriority": MusicProvider.defaultProvider.rawValue,
            "otherPlayers": engine.otherPlayersEnabled,
            "musicSources": MusicSourcePolicy.applicationSettings(),
            "musicSites": MusicSourcePolicy.siteSettings(),
            "wallpaperControls": engine.controlsEnabled,
            "shareFormat": shareCard.format.rawValue,
            "keepHistory": history.enabled,
            "historyCount": history.entries.count,
            "autoUpdate": updater.automatic,
            "version": updater.currentVersion,
            "updateStatus": updater.status ?? "",
        ]
    }

    fileprivate func applySetting(_ key: String, _ value: Any?) {
        let on = value as? Bool ?? false
        switch key {
        case "launchAtLogin": if on != (SMAppService.mainApp.status == .enabled) { toggleLaunchAtLogin() }
        case "paused": engine.paused = on
        case "refreshRate": if let n = (value as? NSNumber)?.intValue { engine.refreshRate = n }
        case "focus": if on != manualFocus { toggleFocusMode() }
        case "hideWhileSharing": if on != hideLyricsWhileSharing { toggleHideWhileSharing() }
        case "useWeather": engine.useWeather = on
        case "beatSync": engine.beatSync = on
        case "musicPriority": if let raw = value as? String, let p = MusicProvider(rawValue: raw) { MusicProvider.defaultProvider = p }
        case "otherPlayers": engine.otherPlayersEnabled = on
        case "musicSource":
            if let item = value as? [String: Any], let bundle = item["bundle"] as? String,
               let enabled = item["enabled"] as? Bool {
                MusicSourcePolicy.setApplicationAllowed(enabled, bundle: bundle)
                engine.musicSourcesChanged()
            }
        case "musicSite":
            if let item = value as? [String: Any], let host = item["host"] as? String,
               let enabled = item["enabled"] as? Bool {
                MusicSourcePolicy.setSiteAllowed(enabled, rule: host)
                engine.musicSourcesChanged()
            }
        case "wallpaperControls": engine.controlsEnabled = on
        case "shareFormat": if let raw = value as? String, let f = ShareCard.Format(rawValue: raw) { shareCard.format = f }
        case "keepHistory": history.enabled = on
        case "autoUpdate":
            updater.automatic = on
            if on { Task { await updater.check(userInitiated: false) } }
        default: break
        }
        home?.pushState()
    }

    fileprivate func settingAction(_ action: String) {
        switch action {
        case "requestScreenRecording": requestScreenRecording()
        case "share": shareLyricCard()
        case "openHistory": openHistory()
        case "clearHistory": clearHistory()
        case "openTemplatesFolder": openTemplatesFolder()
        case "openAutomation":
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
        case "openBuilder": newBuilderTemplate()
        case "checkUpdates": checkForUpdates()
        case "whatsNew": openWhatsNew()
        default: break
        }
        home?.pushState()
    }
}
