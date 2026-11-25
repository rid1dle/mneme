# Spike notes (Task 0, macOS 26.6.2)

1. **Launched from VS Code's terminal, the spike inherits VS Code's clipboard permission.** `accessBehavior` read
   `alwaysAllow` at the first check, before the spike had ever touched the clipboard. macOS attributes the access
   to the responsible process (VS Code). Consequence: anything run from the shell (tests, `--store` live checks)
   never shows Mneme's own alerts; only a LaunchServices launch (`open`, Finder, login item) tests the real app.
2. **The clipboard alert is a developer preview on 26.6.2, off by default.** AppKit has the switch
   `EnablePasteboardPrivacyDeveloperPreview` (found in the shared cache); with it off, every app reads `alwaysAllow`.
   Turned on for the spike only: `defaults write local.mneme.spike EnablePasteboardPrivacyDeveloperPreview -bool yes`.
   So Paste's repeated prompts on this Mac are not this alert; the altered signature dropping Accessibility is the
   likely cause.
3. **With the preview on (log of 2026-11-25 14:30):**
   - Reading `changeCount` and `accessBehavior`: no alert (copies 1-2).
   - Reading `types`: no alert (copies 3-4). Mneme can see what kind of thing was copied for free.
   - Reading the text (copy 5): alert "“Spike” is trying to access the pasteboard." with buttons **Allow Paste** /
     **Don't Allow Paste**, app icon shown. The read returned `nil` (it does not wait for the answer) and the state
     went `default` -> `ask`.
   - **Allow Paste is one-shot.** Under `ask`, the next read raised the alert again ("after 2 more copies this
     came"); reads returned text only when allowed that time. This is the "asks over and over" loop: only
     System Settings > Privacy & Security > Paste from Other Apps > Always Allow ends it.
   - No Info.plist usage-description key exists for it (none in the shared cache): the alert shows only the app's
     name and icon, so the icon must ship before setup triggers it.
4. **Settings pane:** `x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard`.
5. **Always Allow sticks, and so does Accessibility, across rebuilds.** After the user set Spike to Always Allow
   and granted Accessibility: `behavior=alwaysAllow`, `AXIsProcessTrusted()=true`. Rebuilt with changed code (new
   CDHash), both unchanged. A text read under Always Allow returned a value (not `nil`) with no alert. The
   bundle-id designated requirement in `build.sh` is enough.

## What Mneme does with this

- Watch `changeCount` on the timer; read `types` freely (no alert) to know the kind.
- Read contents only when `accessBehavior == .alwaysAllow`. Under `default` or `ask`, never read on the timer:
  every read under `ask` raises the alert again. Setup does the one deliberate read that makes Mneme appear in
  the pane, then sends the user to `Privacy_Pasteboard` to choose Always Allow.
- Today, with the preview off, `accessBehavior` is already `alwaysAllow` for every app, so capture just works;
  the same code is right when Apple turns enforcement on.
- To test the enforced path: `defaults write local.mneme EnablePasteboardPrivacyDeveloperPreview -bool yes`.

## Shelf measurements (Task 7, 2026-11-25, 10,000-item store, Mac under load average 20-35)

- First frame after warm-up: median 51-79 ms, max 122-128 ms over 20 opens (target: median under 100 ms).
- Without warm-up the first open after launch took 649 ms (SwiftUI's first-time setup); Mneme now builds and
  discards the shelf off screen 3 s after launch (827-1178 ms, invisible).
- Physical footprint: 22.4-23.4 MB after 20 opens, 21.9-22.8 MB after 60 s idle, peak 25.8-26.6 MB (target under
  30 MB; Paste 54.2 MB). CPU over idle 0.0%.
- SwiftUI card row is fast enough; no NSCollectionView needed.
