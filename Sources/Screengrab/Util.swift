import AppKit

let screenRecordingSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

func timestamp() -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
    return f.string(from: Date())
}

func screenUnderMouse() -> NSScreen {
    let p = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }

    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        screens.first { $0.displayID == displayID }
    }

    /// Display points with a top-left origin, relative to this screen.
    func displayRect(fromCocoa rect: NSRect) -> CGRect {
        CGRect(x: rect.minX - frame.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    func cocoaRect(fromDisplay rect: CGRect) -> NSRect {
        NSRect(x: frame.minX + rect.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
}

extension CGRect {
    /// Converts between Cocoa's global space (bottom-left origin) and Quartz's (top-left origin). Both are
    /// anchored on the primary screen, so the same flip goes either way.
    func flippedGlobal(primaryHeight: CGFloat) -> CGRect {
        CGRect(x: minX, y: primaryHeight - maxY, width: width, height: height)
    }
}

extension CGPoint {
    func flippedGlobal(primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: x, y: primaryHeight - y)
    }
}

extension NSPanel {
    /// A borderless, non-activating, click-through-capable panel shown on every Space.
    static func overlay(frame: NSRect, level: NSWindow.Level) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = level
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        return panel
    }
}
