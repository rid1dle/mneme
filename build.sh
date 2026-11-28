#!/bin/zsh
# Builds Mneme.app and the test runner with swiftc (no Xcode or SwiftPM needed).
#   ./build.sh          build the app into build/Mneme.app
#   ./build.sh test     build and run the tests (an optional argument filters by name)
#   ./build.sh spike    build the permission spike into build/Spike.app
#   ./build.sh install  build the app and put it in ~/Applications
# Releases: Kit/scripts/release <version> "<notes>" (see Kit/README.md).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
FLAGS=(-O -swift-version 5 -target arm64-apple-macos14.0)

source Kit/scripts/common.sh
KIT=(Kit/Core/{SQLite,KeyCombo,Update}.swift Kit/App/{Hotkey,Updater,UpdatesSection}.swift)

case "${1:-app}" in
  test)
    CORE=(Sources/Core/*.swift(N))
    # App files the tests exercise without a running app (only those that exist yet).
    BRIDGE=(Sources/App/{Paster,Thumbs,Prefs,Shortcuts,StackRelay,ShelfWindow,Chimes,PasteFormatter,RTFReader}.swift(N))
    swiftc -swift-version 5 -target arm64-apple-macos14.0 -o build/tests Kit/Testing/Harness.swift $KIT $CORE $BRIDGE Tests/*.swift
    ./build/tests "${@:2}"
    ;;
  spike)
    sed -e 's/<string>Mneme<\/string>/<string>Spike<\/string>/g' -e 's/local\.mneme/local.mneme.spike/' Resources/Info.plist > build/Spike-Info.plist
    bundle build/Spike.app Spike local.mneme.spike build/Spike-Info.plist Sources/Spike/*.swift
    ;;
  app)
    bundle build/Mneme.app Mneme local.mneme Resources/Info.plist $KIT ${KIT_UI:|KIT} Sources/Core/*.swift Sources/App/*.swift
    ;;
  install)
    "$0" app
    install_app build/Mneme.app
    ;;
esac
