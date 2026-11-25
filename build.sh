#!/bin/zsh
# Builds Mneme.app and the test runner with swiftc (no Xcode or SwiftPM needed).
#   ./build.sh          build the app into build/Mneme.app
#   ./build.sh test     build and run the tests (an optional argument filters by name)
#   ./build.sh spike    build the permission spike into build/Spike.app
#   ./build.sh install  build the app and put it in ~/Applications
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
FLAGS=(-O -swift-version 5 -target arm64-apple-macos14.0)

# Ad-hoc signed with a requirement on the bundle id, not on this build's hash, so the permissions macOS grants
# (clipboard access, Accessibility) still apply after the next build.
sign() { codesign --force --sign - --identifier "$2" --requirements "=designated => identifier \"$2\"" "$1" >/dev/null; }

# bundle <app path> <executable name> <bundle id> <plist> <sources...>
bundle() {
  local app=$1 exe=$2 id=$3 plist=$4; shift 4
  rm -rf "$app.tmp"
  mkdir -p "$app.tmp/Contents/MacOS" "$app.tmp/Contents/Resources"
  swiftc "${FLAGS[@]}" -parse-as-library -o "$app.tmp/Contents/MacOS/$exe" "$@"
  cp "$plist" "$app.tmp/Contents/Info.plist"
  [[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$app.tmp/Contents/Resources/"
  sign "$app.tmp" "$id"
  rm -rf "$app" && mv "$app.tmp" "$app"
  echo "built $app"
}

case "${1:-app}" in
  test)
    CORE=(Sources/Core/*.swift(N))
    # App files the tests exercise without a running app (only those that exist yet).
    BRIDGE=(Sources/App/{Paster,Thumbs,Prefs,Hotkey,Shortcuts,StackRelay}.swift(N))
    swiftc -swift-version 5 -target arm64-apple-macos14.0 -o build/tests $CORE $BRIDGE Tests/*.swift
    ./build/tests "${@:2}"
    ;;
  spike)
    sed -e 's/<string>Mneme<\/string>/<string>Spike<\/string>/g' -e 's/local\.mneme/local.mneme.spike/' Resources/Info.plist > build/Spike-Info.plist
    bundle build/Spike.app Spike local.mneme.spike build/Spike-Info.plist Sources/Spike/*.swift
    ;;
  app)
    bundle build/Mneme.app Mneme local.mneme Resources/Info.plist Sources/Core/*.swift Sources/App/*.swift
    ;;
  install)
    "$0" app
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/Mneme.app.new"
    cp -R build/Mneme.app "$HOME/Applications/Mneme.app.new"
    rm -rf "$HOME/Applications/Mneme.app" && mv "$HOME/Applications/Mneme.app.new" "$HOME/Applications/Mneme.app"
    echo "installed ~/Applications/Mneme.app"
    ;;
esac
