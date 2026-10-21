import AppKit
import UserNotifications

/// A release version such as 1.2.3. Dev builds such as 0.0.0-dev have none, so they never check.
struct Version: Comparable, CustomStringConvertible {
    let parts: [Int]

    init?(_ string: String) {
        let parts = (string.hasPrefix("v") ? string.dropFirst() : Substring(string))
            .split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.contains(nil) else { return nil }
        self.parts = parts.compactMap { $0 }
    }

    var description: String { parts.map(String.init).joined(separator: ".") }

    private func padded(to count: Int) -> [Int] { parts + Array(repeating: 0, count: count - parts.count) }

    static func < (a: Version, b: Version) -> Bool {
        let n = max(a.parts.count, b.parts.count)
        return a.padded(to: n).lexicographicallyPrecedes(b.padded(to: n))
    }

    static func == (a: Version, b: Version) -> Bool { !(a < b) && !(b < a) }
}

/// How this copy got onto the Mac, which decides whether an update can install in place.
enum InstallKind: Equatable {
    case homebrew(brew: URL)
    case manual

    static let appPath = "/Applications/Screengrab.app"

    static func detect(bundle: URL, exists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> InstallKind {
        guard bundle.standardizedFileURL.path == appPath else { return .manual }
        for prefix in ["/opt/homebrew", "/usr/local"] where exists("\(prefix)/Caskroom/screengrab") && exists("\(prefix)/bin/brew") {
            return .homebrew(brew: URL(fileURLWithPath: "\(prefix)/bin/brew"))
        }
        return .manual
    }
}

enum UpdatePolicy: String, CaseIterable {
    case automatic, ask

    static var current: UpdatePolicy {
        get { UserDefaults.standard.string(forKey: "updatePolicy").flatMap(UpdatePolicy.init) ?? .ask }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "updatePolicy") }
    }

    var title: String { self == .automatic ? "Install Automatically" : "Ask First" }
}

struct Release: Equatable {
    let version: Version
    let page: URL

    /// Reads GitHub's latest-release JSON, or the copy of `fields` kept in defaults.
    init?(_ json: [String: Any]) {
        guard let tag = json["tag_name"] as? String, let version = Version(tag),
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        self.version = version
        self.page = page
    }

    var fields: [String: String] { ["tag_name": "v\(version)", "html_url": page.absoluteString] }
}

/// Checks GitHub for a newer release once a day and installs it: in place through Homebrew, or by opening its page.
@MainActor
final class Updater {
    enum State {
        case upToDate, available(Release)
        /// Brew downloads it, then it waits until the user has nothing on screen that a quit would cut short.
        case installing(Release)
        /// Brew is replacing the app and quits it any moment, so nothing new may start.
        case restarting(Release)
        /// The in-place install did not take, so Update opens the release page instead.
        case failed(Release)
    }

    // Overridable in defaults so scripts/test-update.sh can rehearse an update against a local feed and tap.
    private static var latestURL: URL {
        UserDefaults.standard.string(forKey: "updateFeedURL").flatMap(URL.init(string:))
            ?? URL(string: "https://api.github.com/repos/FlorianRiquelme/screengrab/releases/latest")!
    }
    nonisolated static var cask: String { UserDefaults.standard.string(forKey: "updateCask") ?? "FlorianRiquelme/tap/screengrab" }
    private static let lastCheckKey = "updateLastCheck"
    private static let releaseKey = "updateRelease"
    private static let updatedFromKey = "updatedFrom"

    let installKind = InstallKind.detect(bundle: Bundle.main.bundleURL)
    private let running = Version(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
    private(set) var state = State.upToDate
    private let anchor: NSView
    private let isIdle: () -> Bool
    private var timer: Timer?
    private var upgrade: Process?

    private let notifications = NotificationRelay()
    // UserNotifications aborts outside an app bundle, including SwiftPM debug executables.
    private let notificationCenter: UNUserNotificationCenter? =
        Bundle.main.bundleURL.pathExtension == "app" ? .current() : nil

    init(anchor: NSView, isIdle: @escaping () -> Bool) {
        self.anchor = anchor
        self.isIdle = isIdle
        notifications.onClick = { [weak self] in self?.clicked($0) }
        notificationCenter?.delegate = notifications
    }

    /// Whether the user has yet to allow or turn off notifications, so setup should ask.
    var notificationsUndecided: Bool {
        get async { await notificationCenter?.notificationSettings().authorizationStatus == .notDetermined }
    }

    func requestNotifications() {
        notificationCenter?.requestAuthorization(options: [.alert]) { _, _ in }
    }

    var canCheck: Bool { running != nil }

    /// Nil when there is nothing newer.
    var menuTitle: String? {
        switch state {
        case .upToDate: nil
        case .available(let r), .failed(let r): "Update to \(r.version)…"
        case .installing(let r), .restarting(let r): "Updating to \(r.version)…"
        }
    }

    var isInstalling: Bool {
        switch state {
        case .installing, .restarting: true
        default: false
        }
    }

    var isRestarting: Bool { if case .restarting = state { true } else { false } }

    /// For a capture or recording asked for while brew is about to quit the app.
    func explainRestart() {
        guard case .restarting(let r) = state else { return }
        notice("Updating to \(r.version). Screengrab reopens in a moment.", focus: true)
    }

    func start() {
        guard let running else { return }
        let d = UserDefaults.standard
        if let from = d.string(forKey: Self.updatedFromKey).flatMap(Version.init) {
            d.removeObject(forKey: Self.updatedFromKey)
            if from < running {
                tell("Screengrab updated to \(running)", body: "Click for the release notes.", id: "updated.\(running)",
                     fallback: "Updated to \(running).", actions: [TipAction(title: "Release Notes", then: .advance) { NSWorkspace.shared.open(self.notes) }], focus: true)
            }
        }
        if let saved = d.dictionary(forKey: Self.releaseKey).flatMap(Release.init), saved.version > running {
            state = .available(saved)
        }
        // Every 10 minutes: cheap, and it retries an automatic install that waited for the user to finish.
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.tick() }
    }

    private func tick() {
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        if Date().timeIntervalSince(last) >= 24 * 60 * 60 {
            Task { await check(prompted: false) }
        } else {
            settle(prompted: false)
        }
    }

    func check(prompted: Bool) async {
        guard let running else { return }
        var request = URLRequest(url: Self.latestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ $0.statusCode == 200 }) ?? true,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let release = Release(json) else {
            if prompted { notice("Screengrab couldn't reach GitHub. Try again later.", focus: true) }
            return
        }
        UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
        UserDefaults.standard.set(release.fields, forKey: Self.releaseKey)
        guard release.version > running else {
            if prompted { notice("Screengrab is up to date.", focus: true) }
            return
        }
        switch state {
        case .installing, .restarting: return
        case .failed(let r) where r == release: return
        default: state = .available(release)
        }
        settle(prompted: prompted)
    }

    /// Moves an available update along: installs it when automatic and idle, otherwise tells the user once.
    private func settle(prompted: Bool) {
        guard case .available(let release) = state else { return }
        if case .homebrew(let brew) = installKind, UpdatePolicy.current == .automatic {
            if isIdle() { install(release, brew: brew, prompted: false) }
            return
        }
        let verb = installKind == .manual ? "download" : "install"
        if prompted { return notice("Screengrab \(release.version) is out. Choose Update in this menu to \(verb) it.", focus: true) }
        let key = "updateAnnounced.\(release.version)"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        tell("Screengrab \(release.version) is available",
             body: installKind == .manual ? "Click to download it." : "Click to install it. Screengrab reopens when it's done.",
             id: "available.\(release.version)",
             fallback: "Screengrab \(release.version) is out. Choose Update in this menu to \(verb) it.", focus: false)
    }

    private var notes: URL {
        URL(string: "https://github.com/FlorianRiquelme/screengrab/releases/tag/v\(running?.description ?? "")")!
    }

    /// What clicking a notification does, by the kind in its id. The click can reach a later launch than the one that posted it.
    fileprivate func clicked(_ id: String) {
        switch id.split(separator: ".").first {
        case "available": update()
        case "failed":
            let page = if case .failed(let r) = state { r.page } else { URL(string: "https://github.com/FlorianRiquelme/screengrab/releases/latest")! }
            NSWorkspace.shared.open(page)
        case "updated": NSWorkspace.shared.open(notes)
        default: break
        }
    }

    /// News nobody asked for goes out as a notification, which reaches the user even when the menu bar icon is hidden.
    /// A tip on the icon stands in when notifications are turned off.
    private func tell(_ title: String, body: String, id: String, fallback: String, actions: [TipAction] = [], focus: Bool) {
        Task {
            guard let center = notificationCenter,
                  (try? await center.requestAuthorization(options: [.alert])) == true else {
                return notice(fallback, actions: actions, focus: focus)
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    /// The menu's Update item.
    func update() {
        switch (state, installKind) {
        case (.available(let r), .homebrew(let brew)): install(r, brew: brew, prompted: true)
        case (.available(let r), .manual), (.failed(let r), _): NSWorkspace.shared.open(r.page)
        default: break
        }
    }

    private static var log: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Screengrab/update.log")
    }

    private func install(_ release: Release, brew: URL, prompted: Bool) {
        state = .installing(release)
        do {
            let p = try Self.brewProcess(Self.fetchScript, brew: brew, app: InstallKind.appPath, log: Self.log)
            p.terminationHandler = { p in
                let downloaded = p.terminationStatus == 0
                Task { @MainActor in
                    if downloaded { self.restartWhenIdle(release, brew: brew, prompted: prompted) } else { self.installFailed(release, prompted: prompted) }
                }
            }
            try p.run()
            upgrade = p
        } catch {
            installFailed(release, prompted: prompted)
        }
    }

    /// The app relaunches right after the upgrade, so it starts only once no recording, capture or preview is open.
    private func restartWhenIdle(_ release: Release, brew: URL, prompted: Bool) {
        guard let running else { return }
        guard isIdle() else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.restartWhenIdle(release, brew: brew, prompted: prompted) }
            return
        }
        state = .restarting(release)
        UserDefaults.standard.set(running.description, forKey: Self.updatedFromKey)
        do {
            let p = try Self.brewProcess(Self.upgradeScript, brew: brew, app: InstallKind.appPath, log: Self.log)
            p.terminationHandler = { p in
                let upgraded = p.terminationStatus == 0
                Task { @MainActor in
                    // brew upgrade exits 0 without upgrading when the tap does not have the release yet.
                    if upgraded, let installed = Self.installedVersion, installed > running { self.relaunch() }
                    else { self.installFailed(release, prompted: prompted) }
                }
            }
            try p.run()
            upgrade = p
        } catch {
            installFailed(release, prompted: prompted)
        }
    }

    private static var installedVersion: Version? {
        (NSDictionary(contentsOfFile: InstallKind.appPath + "/Contents/Info.plist")?["CFBundleShortVersionString"] as? String).flatMap(Version.init)
    }

    /// brew will not quit an app it runs inside, so the app quits itself and a helper that outlives it reopens the new one.
    private func relaunch() {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", #"while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done; open "$APP""#]
        helper.environment = ["PID": String(getpid()), "APP": InstallKind.appPath, "PATH": "/usr/bin:/bin"]
        guard (try? helper.run()) != nil else { return NSApp.terminate(nil) }
        NSApp.terminate(nil)
    }

    private func installFailed(_ release: Release, prompted: Bool) {
        UserDefaults.standard.removeObject(forKey: Self.updatedFromKey)
        upgrade = nil
        state = .failed(release)
        tell("The update to \(release.version) didn't install", body: "Click to download it instead.", id: "failed.\(release.version)",
             fallback: "The update didn't install. Choose Update in this menu to download it instead.", focus: prompted)
    }

    /// Downloads the new version without touching the running app.
    nonisolated static let fetchScript = #""$BREW" update --quiet; HOMEBREW_NO_AUTO_UPDATE=1 "$BREW" fetch --cask "$CASK""#
    /// Replaces the app on disk. The running copy stays up until it relaunches itself.
    nonisolated static let upgradeScript = #"HOMEBREW_NO_AUTO_UPDATE=1 "$BREW" upgrade --cask "$CASK""#

    nonisolated static func brewProcess(_ script: String, brew: URL, app: String, cask: String = cask, log: URL) throws -> Process {
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        let out = try FileHandle(forWritingTo: log)
        out.seekToEndOfFile()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        var env = ProcessInfo.processInfo.environment
        env["BREW"] = brew.path
        env["APP"] = app
        env["CASK"] = cask
        env["PATH"] = brew.deletingLastPathComponent().path + ":" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = out
        p.standardError = out
        return p
    }

    private func notice(_ text: String, actions: [TipAction] = [], once id: String? = nil, focus: Bool) {
        Tips.notice(Tip(anchor: anchor, text: text, edge: .minY, actions: actions), once: id, focus: focus)
    }
}

/// Hands notification clicks to the updater, and shows its banners even while Screengrab is the active app.
private final class NotificationRelay: NSObject, UNUserNotificationCenterDelegate {
    @MainActor var onClick: (String) -> Void = { _ in }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        .banner
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.identifier
        await MainActor.run { onClick(id) }
    }
}
