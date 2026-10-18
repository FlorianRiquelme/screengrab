#!/bin/bash
# Rehearses a Homebrew in-place update on this Mac with local fake releases, before a real one reaches users.
#
#   scripts/test-update.sh            installs 1.9.0 from a local tap, offers 2.0.0, and opens the app
#   scripts/test-update.sh --fail     offers 3.0.0, which the local tap lacks, so the update must fall back
#   scripts/test-update.sh --cleanup  removes the test tap and settings and reinstalls the real cask
#
# It replaces /Applications/Screengrab.app while it runs; --cleanup puts the real one back.
set -euo pipefail
cd "$(dirname "$0")/.."

TAP=screengrab-test/local
CASK=$TAP/screengrab
REAL_CASK=FlorianRiquelme/tap/screengrab
DOMAIN=io.github.florianriquelme.screengrab
WORK="$PWD/build/update-test"
FEED="$WORK/latest.json"

feed() {
    printf '{"tag_name": "v%s", "html_url": "https://github.com/FlorianRiquelme/screengrab/releases"}\n' "$1" > "$FEED"
    # The app checks at most once a day, so forget the last check.
    defaults delete "$DOMAIN" updateLastCheck 2>/dev/null || true
    defaults delete "$DOMAIN" updateRelease 2>/dev/null || true
}

cask_file() {
    local version=$1 sha
    sha=$(shasum -a 256 "$WORK/Screengrab-$version.zip" | cut -d' ' -f1)
    cat > "$(brew --repository "$TAP")/Casks/screengrab.rb" <<CASK
cask "screengrab" do
  version "$version"
  sha256 "$sha"

  url "file://$WORK/Screengrab-#{version}.zip"
  name "Screengrab"
  desc "Local update rehearsal"
  homepage "https://github.com/FlorianRiquelme/screengrab"

  app "Screengrab.app"

  # As in the real cask: brew quarantines downloads, and the app is not notarized.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/Screengrab.app"]
  end

  uninstall quit: "$DOMAIN"
end
CASK
}

# Every copy shares the bundle ID, so brew's quit would close them all; only the test copy should run.
quit_all() {
    osascript -e "tell application id \"$DOMAIN\" to quit" 2>/dev/null || true
    sleep 1
    pkill -x Screengrab 2>/dev/null || true
}

case "${1:-}" in
--cleanup)
    quit_all
    brew uninstall --cask "$CASK" 2>/dev/null || true
    brew untap "$TAP" 2>/dev/null || true
    for key in updateFeedURL updateCask updateLastCheck updateRelease updatePolicy updatedFrom; do
        defaults delete "$DOMAIN" "$key" 2>/dev/null || true
    done
    rm -rf "$WORK"
    brew install --cask "$REAL_CASK"
    echo "Back on $REAL_CASK."
    ;;
--fail)
    feed 3.0.0
    quit_all
    open /Applications/Screengrab.app
    echo "Offering 3.0.0, which the tap lacks. Update should fall back to the download page."
    ;;
"")
    mkdir -p "$WORK"
    for version in 1.9.0 2.0.0; do
        VERSION=$version scripts/build.sh --no-install
        rm -f "$WORK/Screengrab-$version.zip"
        ditto -c -k --keepParent build/Screengrab.app "$WORK/Screengrab-$version.zip"
    done

    quit_all
    if brew list --cask screengrab &>/dev/null; then brew uninstall --cask screengrab; fi
    [[ -d "$(brew --repository "$TAP")" ]] || brew tap-new --no-git "$TAP" >/dev/null
    mkdir -p "$(brew --repository "$TAP")/Casks"
    cask_file 1.9.0
    HOMEBREW_NO_AUTO_UPDATE=1 brew install --cask "$CASK"
    cask_file 2.0.0

    feed 2.0.0
    defaults write "$DOMAIN" updateFeedURL "file://$FEED"
    defaults write "$DOMAIN" updateCask "$CASK"
    # A first launch again, so the setup question shows.
    for key in tipsSkipped tipsSeen.setup updatePolicy updatedFrom; do
        defaults delete "$DOMAIN" "$key" 2>/dev/null || true
    done
    pkill -x Screengrab 2>/dev/null || true
    open /Applications/Screengrab.app
    echo "1.9.0 is running from $CASK and 2.0.0 is on offer. Update log: ~/Library/Logs/Screengrab/update.log"
    ;;
*)
    echo "usage: scripts/test-update.sh [--fail | --cleanup]" >&2
    exit 1
    ;;
esac
