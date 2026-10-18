import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let recording = RecordingCoordinator()
    private var hotKeys: HotKeys?
    private var selector: CaptureSelector?
    private var lastTarget: CaptureTarget?
    private var scrollCapture: ScrollCapture?

    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private var actionItems: [HotKeyAction: NSMenuItem] = [:]
    private var retentionItems: [NSMenuItem] = []
    private let saveFolderMenu = NSMenu()
    private let updateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let updateSeparator = NSMenuItem.separator()
    private var policyItems: [NSMenuItem] = []
    private lazy var updater = Updater(anchor: statusItem.button!) { [unowned self] in self.isIdle }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setIcon(recording: false)
        pruneScreenshotCache()
        statusItem.menu = buildMenu()
        hotKeys = HotKeys { [weak self] action in self?.perform(action) }
        recording.onStateChange = { [weak self] state in self?.recorderChanged(state) }

        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--open"), i + 1 < args.count {
            let url = URL(fileURLWithPath: args[i + 1])
            let content: PreviewContent = ["mov", "mp4"].contains(url.pathExtension.lowercased())
                ? .recording(url, interruption: nil)
                : .screenshot(url, ownsFile: false)
            Task { await PreviewWindow.show(content) }
        }
        if args.contains("--show-hud") {
            recording.toggle()
        }
        // The status item's window has no frame for a moment after launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if !args.contains("--open") && !args.contains("--show-hud") { self.showSetupTips() }
            self.updater.start()
        }
    }

    /// Nothing on screen that an update's quit and relaunch would cut short.
    private var isIdle: Bool {
        guard case .idle = recording.state else { return false }
        return selector == nil && scrollCapture == nil && !PreviewWindow.isShowing && !Tips.isShowing && NSApp.modalWindow == nil
    }

    private func showSetupTips() {
        guard let button = statusItem.button else { return }
        let keys = "\(shortcut(for: .captureArea)) captures an area, \(shortcut(for: .repeatCapture)) repeats it, "
            + "\(shortcut(for: .scrollingCapture)) captures a scrolling page, \(shortcut(for: .toggleRecording)) records."
        var tips = [
            Tip(anchor: button, text: "Screengrab lives here. " + keys, edge: .minY),
            Tip(anchor: button, text: "Copied screenshots are \(CacheRetention.current.phrase). Saved ones are kept. Change it under Delete Copied Screenshots in this menu.", edge: .minY),
        ]
        if case .homebrew = updater.installKind {
            tips.append(Tip(anchor: button, text: "Install updates automatically? Screengrab checks GitHub once a day.", edge: .minY, actions: [
                TipAction(title: UpdatePolicy.automatic.title, then: .advance) { UpdatePolicy.current = .automatic },
                TipAction(title: UpdatePolicy.ask.title, then: .next) { UpdatePolicy.current = .ask },
            ]))
        }
        if !CGPreflightScreenCaptureAccess() {
            tips.append(Tip(anchor: button, text: "Screengrab needs Screen Recording permission to capture. Turn it on in System Settings; macOS may ask you to reopen Screengrab.",
                            edge: .minY, actions: [TipAction(title: "Open System Settings") {
                // Requesting first is what lists Screengrab in the pane.
                CGRequestScreenCaptureAccess()
                NSWorkspace.shared.open(screenRecordingSettingsURL)
            }]))
        }
        Tips.show(.setup, tips)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        updateItem.target = self
        menu.addItem(updateItem)
        menu.addItem(updateSeparator)
        for b in hotKeyTable {
            let item = NSMenuItem(title: b.title, action: #selector(menuAction(_:)), keyEquivalent: b.character)
            item.keyEquivalentModifierMask = b.modifiers
            item.target = self
            item.tag = Int(b.action.rawValue)
            actionItems[b.action] = item
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let folder = NSMenuItem(title: "Open Recordings Folder", action: #selector(openRecordingsFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)
        let retention = NSMenuItem(title: "Delete Copied Screenshots", action: nil, keyEquivalent: "")
        retention.submenu = NSMenu()
        retentionItems = CacheRetention.allCases.map { r in
            let item = NSMenuItem(title: r.menuTitle, action: #selector(setRetention(_:)), keyEquivalent: "")
            item.target = self
            item.tag = r.rawValue
            retention.submenu?.addItem(item)
            return item
        }
        menu.addItem(retention)
        let saveFolder = NSMenuItem(title: "Save Screenshots To", action: nil, keyEquivalent: "")
        saveFolder.submenu = saveFolderMenu
        menu.addItem(saveFolder)
        let updates = NSMenuItem(title: "Updates", action: nil, keyEquivalent: "")
        updates.submenu = NSMenu()
        if case .homebrew = updater.installKind {
            policyItems = UpdatePolicy.allCases.map { policy in
                let item = NSMenuItem(title: policy.title, action: #selector(setUpdatePolicy(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = policy.rawValue
                updates.submenu?.addItem(item)
                return item
            }
            updates.submenu?.addItem(.separator())
        }
        // Dev builds have no version to compare, so the item stays disabled.
        let check = NSMenuItem(title: "Check for Updates", action: updater.canCheck ? #selector(checkForUpdates) : nil, keyEquivalent: "")
        check.target = self
        updates.submenu?.addItem(check)
        menu.addItem(updates)
        loginItem.target = self
        menu.addItem(loginItem)
        let tips = NSMenuItem(title: "Show Tips Again", action: #selector(showTipsAgain), keyEquivalent: "")
        tips.target = self
        menu.addItem(tips)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateItem.title = updater.menuTitle ?? ""
        updateItem.isHidden = updater.menuTitle == nil
        updateSeparator.isHidden = updateItem.isHidden
        updateItem.action = updater.isInstalling ? nil : #selector(update)
        for item in policyItems { item.state = item.representedObject as? String == UpdatePolicy.current.rawValue ? .on : .off }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        for item in retentionItems { item.state = item.tag == CacheRetention.current.rawValue ? .on : .off }
        let current = SaveFolder.current.standardizedFileURL
        let folders = SaveFolder.presets.contains { $0.standardizedFileURL == current } ? SaveFolder.presets : SaveFolder.presets + [current]
        saveFolderMenu.items = folders.map { url in
            let item = NSMenuItem(title: FileManager.default.displayName(atPath: url.path), action: #selector(setSaveFolder(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.state = url.standardizedFileURL == current ? .on : .off
            return item
        }
        saveFolderMenu.addItem(.separator())
        let choose = NSMenuItem(title: "Choose Folder…", action: #selector(chooseSaveFolder), keyEquivalent: "")
        choose.target = self
        saveFolderMenu.addItem(choose)
    }

    private func setIcon(recording: Bool) {
        let name = recording ? "record.circle.fill" : "camera.viewfinder"
        var image = NSImage(systemSymbolName: name, accessibilityDescription: "Screengrab")
        if recording {
            image = image?.withSymbolConfiguration(.init(paletteColors: [.systemRed]))
        }
        image?.isTemplate = !recording
        statusItem.button?.image = image
    }

    private func recorderChanged(_ state: RecorderState) {
        switch state {
        case .idle:
            setIcon(recording: false)
            actionItems[.toggleRecording]?.title = "Record…"
        case .configuring:
            actionItems[.toggleRecording]?.title = "Close Recording Panel"
        case .recording:
            setIcon(recording: true)
            actionItems[.toggleRecording]?.title = "Stop Recording"
        case .starting, .stopping:
            break
        }
    }

    @objc private func menuAction(_ item: NSMenuItem) {
        if let action = HotKeyAction(rawValue: UInt32(item.tag)) { perform(action) }
    }

    private func perform(_ action: HotKeyAction) {
        switch action {
        case .captureArea: captureArea()
        case .repeatCapture: repeatCapture()
        case .toggleRecording: recording.toggle()
        case .scrollingCapture: scrollingCapture()
        }
    }

    /// Starts a scrolling capture, or finishes the running one.
    private func scrollingCapture() {
        if let scrollCapture { return scrollCapture.finish() }
        guard selector == nil else { return }
        scrollCapture = ScrollCapture.begin { [weak self] error in
            self?.scrollCapture = nil
            if let error { self?.showCaptureFailure(error) }
        }
    }

    private func captureArea() {
        guard selector == nil, scrollCapture == nil else { return }
        selector = CaptureSelector.begin(.screenshot) { [weak self] target in
            self?.selector = nil
            if let target { self?.capture(target) }
        }
    }

    /// Recaptures the last target without any selection UI, or selects anew when there is none or it is gone.
    private func repeatCapture() {
        guard selector == nil else { return }
        if let lastTarget { capture(lastTarget) } else { captureArea() }
    }

    private func capture(_ target: CaptureTarget) {
        Task {
            do {
                let url = try Screenshot.writePNG(try await Screenshot.capture(target))
                lastTarget = target
                await PreviewWindow.show(.screenshot(url, ownsFile: true))
            } catch CaptureError.targetGone {
                lastTarget = nil
                captureArea()
            } catch {
                showCaptureFailure(error)
            }
        }
    }

    private func showCaptureFailure(_ error: Error) {
        let alert = NSAlert()
        NSApp.activate()
        guard !CGPreflightScreenCaptureAccess() else {
            alert.messageText = "Screenshot failed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return
        }
        alert.messageText = "Screengrab needs Screen Recording permission"
        alert.informativeText = "Allow Screengrab in System Settings > Privacy & Security > Screen & System Audio Recording, then try again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(screenRecordingSettingsURL)
        }
    }

    @objc private func openRecordingsFolder() {
        let dir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Screengrab")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    @objc private func setRetention(_ item: NSMenuItem) {
        CacheRetention.current = CacheRetention(rawValue: item.tag) ?? .sevenDays
        pruneScreenshotCache()
    }

    @objc private func setSaveFolder(_ item: NSMenuItem) {
        if let url = item.representedObject as? URL { SaveFolder.current = url }
    }

    @objc private func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = SaveFolder.current
        panel.prompt = "Choose"
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { SaveFolder.current = url }
    }

    @objc private func update() { updater.update() }

    @objc private func checkForUpdates() {
        Task { await updater.check(prompted: true) }
    }

    @objc private func setUpdatePolicy(_ item: NSMenuItem) {
        if let raw = item.representedObject as? String, let policy = UpdatePolicy(rawValue: raw) { UpdatePolicy.current = policy }
    }

    @objc private func showTipsAgain() {
        Tips.resetAll()
        DispatchQueue.main.async { self.showSetupTips() }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
