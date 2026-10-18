import Foundation
import Testing
@testable import Screengrab

@Suite struct VersionTests {
    @Test func comparesNumerically() throws {
        #expect(try #require(Version("1.10.0")) > #require(Version("1.9.3")))
        #expect(try #require(Version("0.9.0")) < #require(Version("1.0.0")))
        #expect(try #require(Version("1.0")) == #require(Version("1.0.0")))
    }

    @Test func readsGitHubTags() throws {
        #expect(try #require(Version("v1.2.3")) == #require(Version("1.2.3")))
        #expect(Version("v1.2.3")?.description == "1.2.3")
    }

    @Test func devBuildsHaveNoVersion() {
        #expect(Version("0.0.0-dev") == nil)
        #expect(Version("") == nil)
    }
}

@Suite struct InstallKindTests {
    private let app = URL(fileURLWithPath: "/Applications/Screengrab.app")

    @Test func caskInstallUsesItsBrew() {
        let present: Set = ["/usr/local/Caskroom/screengrab", "/usr/local/bin/brew", "/opt/homebrew/bin/brew"]
        #expect(InstallKind.detect(bundle: app, exists: present.contains) == .homebrew(brew: URL(fileURLWithPath: "/usr/local/bin/brew")))
    }

    @Test func zipInstallIsManual() {
        #expect(InstallKind.detect(bundle: app, exists: ["/opt/homebrew/bin/brew"].contains) == .manual)
    }

    @Test func copyOutsideApplicationsIsManual() {
        let present: Set = ["/opt/homebrew/Caskroom/screengrab", "/opt/homebrew/bin/brew"]
        #expect(InstallKind.detect(bundle: URL(fileURLWithPath: "/Users/me/build/Screengrab.app"), exists: present.contains) == .manual)
        #expect(InstallKind.detect(bundle: app, exists: present.contains) == .homebrew(brew: URL(fileURLWithPath: "/opt/homebrew/bin/brew")))
    }
}

@Suite struct BrewProcessTests {
    /// Runs `script` against a fake brew that records its calls and fails `brew upgrade` with status 3.
    private func run(_ script: String) throws -> (status: Int32, calls: [Substring], log: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let brew = dir.appendingPathComponent("brew")
        try """
        #!/bin/sh
        echo "$* auto=${HOMEBREW_NO_AUTO_UPDATE:-}" >> "\(dir.path)/calls"
        [ "$1" = upgrade ] && exit 3
        exit 0
        """.write(to: brew, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brew.path)
        let log = dir.appendingPathComponent("logs/update.log")
        try "earlier run\n".write(to: dir.appendingPathComponent("logs", isDirectory: true).appendingPathComponent("update.log").creatingParent(), atomically: true, encoding: .utf8)

        let p = try Updater.brewProcess(script, brew: brew, app: "/nonexistent/Screengrab.app", log: log)
        try p.run()
        p.waitUntilExit()
        let calls = try String(contentsOf: dir.appendingPathComponent("calls"), encoding: .utf8).split(separator: "\n")
        return (p.terminationStatus, calls, try String(contentsOf: log, encoding: .utf8))
    }

    @Test func fetchUpdatesTheTapThenDownloadsWithoutUpgrading() throws {
        let r = try run(Updater.fetchScript)
        #expect(r.status == 0)
        #expect(r.calls.count == 2)
        #expect(r.calls.first?.hasPrefix("update --quiet") == true)
        #expect(r.calls.last == "fetch --cask FlorianRiquelme/tap/screengrab auto=1")
        #expect(!r.log.contains("/nonexistent/Screengrab.app"), "the download leaves the running app alone")
        #expect(r.log.hasPrefix("earlier run"), "the log keeps earlier runs")
    }

    @Test func upgradeReportsItsStatusAndReopensTheApp() throws {
        let r = try run(Updater.upgradeScript)
        #expect(r.status == 3, "exit status is brew upgrade's, not open's")
        #expect(r.calls == ["upgrade --cask FlorianRiquelme/tap/screengrab auto=1"])
        #expect(r.log.contains("/nonexistent/Screengrab.app"), "reopens the app even when the upgrade fails")
    }
}

private extension URL {
    func creatingParent() throws -> URL {
        try FileManager.default.createDirectory(at: deletingLastPathComponent(), withIntermediateDirectories: true)
        return self
    }
}
