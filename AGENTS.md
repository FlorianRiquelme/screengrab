# Agents

Screengrab is a macOS 26 menu bar app in Swift (SwiftPM, AppKit, no SwiftUI or Combine).

## The rule: the UI stays out of the way

The core loop is capture, one action, gone. Every change must keep that loop this short.

- Do not add buttons, panels, or settings to the capture, screenshot preview, scrolling capture, or recording screens.
- Explain unclear behavior with a one-time tip in `Sources/Screengrab/Tips.swift`, not with a new control.
- Settings go in the menu bar menu as items or submenus. Never add a settings window.
- A new on-screen control needs the maintainer's explicit OK before you build it.

## Build and test

- `swift build` builds a debug binary.
- `scripts/test.sh` runs the test suite (Swift Testing).
- `scripts/build.sh` builds, signs, and installs `Screengrab.app` to `~/Applications`.
- `Screengrab --open <path>` opens an image or a `.mov` in the matching preview.

Match the existing style: terse code, comments only for a non-obvious why, `///` doc lines on types.
