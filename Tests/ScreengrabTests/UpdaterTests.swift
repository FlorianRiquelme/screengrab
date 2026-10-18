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

@Suite struct UpgradeProcessTests {
    @Test func updatesThenUpgradesTheCaskAndReportsTheUpgradeStatus() throws {
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

        let p = try Updater.upgradeProcess(brew: brew, app: "/nonexistent/Screengrab.app", log: log)
        try p.run()
        p.waitUntilExit()

        #expect(p.terminationStatus == 3, "exit status is brew upgrade's, not open's")
        let calls = try String(contentsOf: dir.appendingPathComponent("calls"), encoding: .utf8).split(separator: "\n")
        #expect(calls.count == 2)
        #expect(calls.first?.hasPrefix("update --quiet") == true)
        #expect(calls.last == "upgrade --cask FlorianRiquelme/tap/screengrab auto=1")
        #expect(try String(contentsOf: log, encoding: .utf8).contains("/nonexistent/Screengrab.app"), "reopens the app even when the upgrade fails")
    }
}
