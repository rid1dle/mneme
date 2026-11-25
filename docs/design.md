# Mneme: design

## Why

Mneme replaces Paste (the paid clipboard manager, v5.0.8 installed here). Paste does the job but keeps asking for
permissions over and over. Two likely causes, both handled below: the installed copy's signature is altered (so
macOS treats it as a new app and drops its Accessibility grant), and macOS 15.4+ asks before an app reads the
clipboard on its own ("Paste from other apps"; while an app is set to Ask, the alert can come back). Mneme should
do what Paste does on the Mac, look as good, and be lighter: Paste's physical footprint (Activity Monitor's Memory
column) is 54.2 MB idle on this machine, peak 82.1 MB, with 110 MB of history on disk.

**Scope** is the feature list in this document (agreed with the user, plus themes and Settings); it is not a
feature-for-feature audit of Paste.

The machine is a fanless M1 MacBook Air with 16 GB that already runs hot under Claude sessions, builds and
browsers. Mneme runs all day, so idle cost matters more than anything else.

## Goals

1. **Never miss a copy, never paste the wrong thing.** Every copy in any app lands in history with its source app
   and time; picking an item pastes exactly that item into the app the user was in.
2. **Fast to reach.** A global shortcut (default ⇧⌘V, changeable) slides a shelf up from the bottom of the screen
   over any app, full-screen ones included. Typing searches at once; arrows move; Return pastes; Esc closes.
3. **Find anything.** Search covers the text of every item, including text read from images and screenshots,
   plus link titles, source app and pinboard. Filters by type, source app and date.
4. **Light.** Under 30 MB of memory when the shelf is closed, ~0% CPU idle, no memory creep over days of uptime.
5. **Asks once.** Two permissions, both handled in first-launch setup and never nagged about after:
   - **Clipboard access** ("Paste from other apps", macOS 15.4+): required for capture. Setup triggers the one system
     alert and then sends the user to set Mneme to Always Allow. If it is not Always Allow, capture stops and the
     menu bar icon and shelf show one quiet "Capture is off" note with a button to the setting; Mneme does not read
     the clipboard again until the setting changes (it checks `NSPasteboard.accessBehavior`, which does not alert).
   - **Accessibility:** optional, only to press ⌘V for the user. Saying no leaves a working app.

## Non-goals (for now)

- iOS app and sync between devices. Deferred, not dropped: the data model keeps stable ids, change times and
  deletion markers so sync can be added later without migrating history (see Store).
- Importing Paste's history.
- Shortcuts.app actions, AI features, telemetry.

## Anti-goals (a failure even if it works)

- Any permission prompt after the first one, including after rebuilding the app.
- Saving a password or other secret a password manager marks as such.
- A shelf that takes noticeably long to appear (target: first frame under 100 ms with 10,000 items).
- Heating the Mac: background work (reading text from images) must not run while the user is busy.
- Losing pinned items to history cleanup.

## Approaches considered

| Approach | Trade-off | Decision |
| --- | --- | --- |
| AppKit shell (panel, menu bar item, hotkey) + SwiftUI views, SQLite | ~25-35 MB idle; themes and glass easy; same stack as Kenosis | **Chosen by the user** |
| All AppKit (NSCollectionView, layers), no SwiftUI | Lightest (~15-20 MB), but 2-3x the code, themes and glass harder | Declined |
| Web UI (Electron/Tauri) | 100+ MB; worse panel behaviour | Ruled out |

The idle target holds in the chosen approach because the shelf's view tree is torn down when it closes (see Shelf).

## How it is built (decided)

- **Swift + SwiftUI + AppKit, Apple frameworks only, no third-party packages.** SQLite via the system `libsqlite3`
  (with FTS5). Built with `swiftc` from `build.sh` into `Mneme.app`, like Kenosis, because Xcode is not installed
  and SwiftPM in the installed Command Line Tools is broken. Repo `~/work/mneme`. Target macOS 14 or later; Liquid
  Glass (`glassEffect`) where the SDK and OS have it, materials otherwise.
- **Signing so permissions stick.** Ad-hoc signed with a designated requirement on the bundle id
  (`--requirements '=designated => identifier "local.mneme"'`), exactly as Kenosis does for Full Disk Access, so
  the Accessibility grant survives every rebuild.
- **Agent app.** `LSUIElement`: no Dock icon; a menu bar item (Open, Pause capture, Settings, Quit) and the shortcut
  are the ways in. Open at login via `SMAppService`, offered in setup.

### Capture

- macOS gives no clipboard-change notification, so a timer checks `NSPasteboard.general.changeCount` (every
  0.5 s, with generous timer leeway so the system coalesces wake-ups). Only when the count changes are types read,
  and only while `accessBehavior` is Always Allow (see Goal 5).
- **First build step is a spike** on this Mac (macOS 26.6.2) that proves: reading `changeCount` and
  `accessBehavior` never raises the alert; with Always Allow, reading contents never does either; and the
  Accessibility grant survives a rebuild with the bundle-id signing. Capture is built on what the spike shows.
- **Skipped:** items carrying `org.nspasteboard.ConcealedType`, `TransientType` or `AutoGeneratedType`; anything
  copied while an excluded app is frontmost (1Password and Keychain Access excluded by default, editable list);
  Mneme's own writes (it records the change count it produced); everything while capture is paused.
- **Kinds:** text, rich text (RTF/HTML kept alongside plain text), image, file(s), link, color (a copied string that
  is only a hex or rgb()/hsl() color). Each item stores the pasteboard representations needed to paste it back
  faithfully, up to a per-item size cap (50 MB); files are stored as references (path + bookmark), not contents,
  and a card shows when the file no longer exists.
- **Duplicates:** content hash; copying something already in history moves it to the front instead of adding a copy.
- **Source app:** frontmost app at capture time (bundle id, name); its icon is fetched from `NSWorkspace` when
  shown, not stored.

### Store

- `~/Library/Application Support/Mneme/mneme.sqlite` (WAL). Large payloads (images, rich text, other blobs) live
  as files under `Blobs/`, named by content hash; thumbnails (made once at capture, about 400 px, via ImageIO) under
  `Thumbs/`.
- Tables: `items` (UUID id, kind, title for renames, plain text, preview text, hash, sizes, source app, link title
  and image, OCR text, created / updated / last used times, `deleted_at`), `representations` (item id, type,
  inline bytes or blob name), `pinboards` (UUID id, name, color, order, times, `deleted_at`), `pins` (pinboard id,
  item id; an item can be on several pinboards). `items.in_history` says whether the item shows in History. An FTS5 table indexes text, title, OCR text, link title and app
  name.
- Sync-ready from day one: UUID ids, `updated_at` on every row, deletions recorded as `deleted_at` and purged later.
- **History and pinboards are independent views of the same item** (builder's call):
  - Deleting from History clears `in_history`; deleting from a pinboard removes that pin; an item with neither is
    deleted (`deleted_at`). "Delete everywhere" in the context menu does both, with a confirmation if it is pinned.
  - Copying an item again puts it back at the front of History (`in_history` set, `last_used_at` updated); its pins
    are unchanged.
- **Retention:** History entries whose last use is older than the chosen age (default 30 days) leave History at
  launch and daily; pinned items stay on their pinboards. Items left in neither are deleted, and unreferenced
  blobs and thumbs are removed in the same pass.

### Shelf

- A borderless `NSPanel` (non-activating, can become key so typing works, joins all spaces, shows over full-screen
  apps) docked to the bottom of the screen the pointer is on, sliding up when opened. The app the user was in
  stays frontmost underneath.
- Top row: search field, type filters (All, Text, Images, Links, Files, Colors), then pinboard tabs (History first,
  then each pinboard with its color). Below: a horizontal row of cards, newest first. Each card shows source app
  icon and time, a preview (text excerpt, thumbnail, link title and image, file icon and name, color swatch), and a
  footer (character count, dimensions, file count). ⌘1-⌘9 paste the first nine visible cards.
- The card row is lazy and fed in pages from SQLite as the user scrolls; thumbnails load from disk off the main
  thread into a size-limited cache.
- **On close, the SwiftUI view tree is removed from the panel and the thumbnail cache emptied.** Only the capture
  timer and the store stay alive between opens.

### Actions on an item

Paste, paste as plain text, Quick Look-style full preview (Space), edit (text items; keeps the id), rename, copy
without pasting, drag out of the shelf, delete, add to / remove from pinboards. Context menu and keyboard shortcuts
for each.

- **Pasting:** write the item's representations to the pasteboard (marked as Mneme's own), close the shelf, and,
  if Accessibility is granted, post ⌘V to the previous app with `CGEvent`. Without it, the item is just copied and a
  short "Copied, press ⌘V" note shows; Settings > General offers to turn auto-paste on. Mneme checks
  `AXIsProcessTrusted()` silently and never prompts on its own after setup.
- **Paste stack:** a toggle (menu bar and shortcut) starts a stack; copies made while it is on are collected in
  order; a "paste next" shortcut pastes the next one and advances. The stack shows as its own strip in the shelf.

### Search

FTS5 prefix query over the indexed fields, debounced (~80 ms), combined with the type / app / date filters and the
selected pinboard. Results replace the card row in the same paged way.

### Reading text from images

Vision text recognition runs on images in a background queue at utility priority, only when the user has been idle
for a while (no input for 60 s) and the thermal state is nominal or fair; it stops as soon as input resumes. Each
image is read once; its text is added to the search index.

### Link previews

When a link is copied, Mneme fetches the page's title and preview image (head of the page only, small byte limit,
short timeout). On by default with a switch in Settings > Privacy to turn it off. No other network use.

### Themes

Appearance: System, Light, Dark. Accent color: presets plus a custom picker. Shelf style: Glass or Solid. A few
named presets combine these; the user can pick a preset and then adjust. Themes are applied through the SwiftUI
environment so every view follows one source.

### Settings (⌘,)

- **General:** shortcut recorder, paste-next shortcut, open at login, auto-paste (Accessibility status and a button
  to open the system setting), menu bar icon.
- **History:** keep for (1 day ... forever), kinds to save, clear history (confirmation; pinboards untouched).
- **Privacy:** excluded apps (add from running apps or Finder), skip secrets (on, explained), link previews, pause
  capture.
- **Appearance:** presets, appearance, accent, shelf style, card size.
- **Pinboards:** create, rename, recolor, reorder, delete.

### First-launch setup

One sheet, shown once: the shortcut (with a recorder), open at login, clipboard access (triggers the system alert,
then a button to the Paste from other apps setting, and a live tick once it is Always Allow), and the
Accessibility explanation with a button to its system setting.

### Testing

- A `swiftc`-built test runner (`./build.sh test`), as in Kenosis, over the core: kind detection, skip rules,
  dedup, retention (pinned kept, blobs collected), FTS query building, store round-trips and sync fields, paste
  stack order.
- Launch options for screenshots of the shelf and Settings from a made-up store (light, dark, glass, solid, empty,
  10,000 items), captured from inside the app as in Kenosis (no Screen Recording permission needed).
- Memory: measured as physical footprint (`vmmap --summary`, same as Activity Monitor and the Paste figure above)
  after open/close cycles and after a day of uptime. Target under 30 MB idle; never above Paste's 54 MB.
- **If targets clash** (builder's call): measure in an early spike with 10,000 made-up items. Opening speed (first
  frame under 100 ms) wins over a few MB. If the SwiftUI card row is what misses, the card row alone moves to
  AppKit (`NSCollectionView`) and the rest stays SwiftUI. If rebuilding the tree on each open is too slow, keep the
  tree for a few minutes after closing, then tear it down.

## Left to the builder

File layout, the exact page size and cache limits, the default preset names and colors, animation timing, the
icon (drawn in code, as for Kenosis), and the default paste-next shortcut.
