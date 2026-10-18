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
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
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
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        for item in retentionItems { item.state = item.tag == CacheRetention.current.rawValue ? .on : .off }
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
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
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

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
