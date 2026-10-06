# PkgSenderMac

<img width="2280" height="1466" alt="MARVEL Tōkon- Fighting Souls 2468C - 2026-10-04 12 17 07" src="https://github.com/user-attachments/assets/0ddc7a1f-68dc-4ce7-9580-230ee92a3288" />


A native macOS port of [Loopayeh/pkg-sender](https://github.com/Loopayeh/pkg-sender)  
(Windows / .NET / Avalonia). Swift 6 + SwiftUI, zero third-party dependencies,  
runs natively on both Apple Silicon and Intel.

- **Requirements**: macOS 12 Monterey or later
- **Architectures**: Universal (arm64 + x86_64)
- **UI languages**: English / 简体中文 / 繁體中文 / 日本語

[简体中文说明](README.zh-CN.md)

---

## Quick start

```bash
cd PkgSenderMac
./build.sh --arch auto     # build (recommended: adapts to the local toolchain)
open build/PkgSender.app
```

`--arch auto` builds every architecture the local toolchain can link. An  
Apple Silicon Mac with only the Command Line Tools can produce arm64; install  
the full Xcode to get a Universal binary.

Other modes:

```bash
./build.sh                 # require arm64 + x86_64 (needs full Xcode)
./build.sh --arch arm64    # Apple Silicon only (fastest)
./build.sh --arch x86_64   # Intel only
```

---

## Usage

1. Enter the console IP (PS5 / PS4) at the top and press `Test`; `Detect`  
   searches the local network automatically.
2. Press **`+ Add folder`** and pick a directory — **scanning starts  
   immediately**, there is no separate scan step. To sweep an entire volume use  
   `Library ▸ Scan drives…` (⌘D).
3. The card grid shows the results:
   - **Click** to select, **⌘-click** to add, **⇧-click** for a range,  
     **double-click** to send
   - The `Library` menu offers Select all ⌘A / Invert ⌘⇧I / Select none ⌘.
4. With a selection, `Send PKG` (⌘S) enqueues it. PS5 pushes over the Range  
   service, PS4 over RPI / GoldHEN.
5. Image containers (`.exfat` / `.ffpkg` / `.ffpfsc`) go to the console's  
   `/data/homebrew` via `Copy images` (⌘I), with resume and overwrite support.

Queue rows can be ⏸ paused / ▶ resumed / ✕ removed / ▲▼ reordered; `Pause all`  
freezes every task at once. Pausing is resumable — the console continues from  
the break point instead of re-downloading.

The UI language can be switched from the menu bar's `Language` menu (defaults to  
following the system).

---

## Project layout

```
PkgSenderMac/
├── Package.swift              # SPM manifest, platforms: [.macOS(.v12)]
├── build.sh                   # build + bundle .app + icon + sign
├── Sources/
│   ├── PkgSenderCore/         # pure-Swift core (no UI, unit-testable, CLI-reusable)
│   │   ├── Models/            # GameItem / QueueEntry / AppSettings / formatting
│   │   ├── Parsing/           # PKG parsing: SFO, param.json, CNT/EXFAT, icons, digests
│   │   ├── Networking/        # HTTP Range server, PS5 client, PS4 RPI/GoldHEN, discovery
│   │   └── Services/          # library scanning, settings persistence
│   └── PkgSenderApp/          # executable target (SwiftUI + AppKit)
│       ├── PkgSenderApp.swift # @main / AppDelegate / menu commands
│       ├── AppModel.swift     # @MainActor ObservableObject: global state + queue driver
│       ├── RootView.swift     # main window: header / toolbar / status bar / drag & drop
│       ├── LibraryPanel.swift # card grid, search & filter, multi-select gestures
│       ├── QueuePanel.swift   # send queue, progress, pause / reorder
│       ├── Dialogs.swift      # About / Guide / Switch console / resume-overwrite
│       ├── AppTheme.swift     # design tokens and shared controls
│       ├── L10n.swift         # runtime localization (4 languages)
│       ├── AppSupport.swift   # NSOpenPanel / pasteboard / notifications
│       ├── LoginItemManager.swift
│       ├── UpdateService.swift  # version string only
│       └── Resources/         # icons, GoldHEN payload, {en,zh-Hans,zh-Hant,ja}.lproj
├── Tests/PkgSenderCoreTests/  # core unit tests
└── build/PkgSender.app        # build artifact
```

The core has no third-party dependencies; the app depends only on the core and  
system frameworks. Networking is built on `URLSession` + BSD sockets — no  
SwiftNIO or similar.

---

## Implementation notes

| Capability                          | macOS implementation                                                                                                      |
| ----------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| File server                         | Own HTTP/1.1 (`RangeHTTPServer`): GET/HEAD, `/pkg/{id}`, `/catalog`, Range `200/206/416`, keep-alive, resumable transfers |
| PS5 push                            | `URLSession` against `12800/9090`: `/api`, `/api/install`, `/api/files/pull`                                              |
| PS4 push                            | RPI `POST /api/install`; falls back to GoldHEN binloader injection + a bin-layer manifest                                 |
| Console discovery                   | `getifaddrs` for the real IPv4 address, skipping `lo0`/virtual NICs; UDP 12801 beacon + TCP probe                         |
| Launch at login                     | `SMAppService.mainApp` on macOS 13+; writes a LaunchAgent plist on 12                                                     |
| Notifications / pasteboard / panels | `UNUserNotificationCenter` / `NSPasteboard` / `NSOpenPanel`                                                               |

Two bugs were fixed relative to upstream: dropped image containers were ignored,  
and legacy PS4 packages (`\x7FPKG` magic) were skipped.

### macOS 12 compatibility

- The deployment target is pinned to `arm64/x86_64-apple-macosx12.0`; `otool`  
  confirms `minos 12.0`.
- No Observation, `NavigationSplitView`, `ShareLink` or `#Preview`; state goes  
  through `@MainActor ObservableObject` + `@Published`.
- `onChange` must use the **single-parameter** form (the two-parameter form is  
  macOS 14+).
- `@FocusState`'s projected value is not a `Binding<Bool>`, so it cannot be  
  passed straight to a parameter that wants a `Binding`.

---

## Localization

The UI language can be switched from the menu bar's `Language` menu — macOS has  
no per-app language override, so this is done in-app rather than through system  
settings. It follows the system by default, and locales such as `zh-Hant-TW`  
fall back to Traditional Chinese correctly.

Strings live in `Sources/PkgSenderApp/Resources/<lang>.lproj/Localizable.strings`  
using the standard macOS layout, so `genstrings` / Xcode can extract them.  
**Re-run `./build.sh` after adding or changing translations** (the `.lproj`  
directories are copied into `PkgSenderMac_PkgSenderApp.bundle`).

---

## Distribution

The app produced by `build.sh` is **ad-hoc signed**, so it is quarantined when  
copied to another Mac. Before sharing, strip the quarantine flag and re-sign it:

```bash
xattr -r -d com.apple.quarantine /Applications/PkgSender.app
codesign -f -s - --deep /Applications/PkgSender.app
```



---

## Testing and limitations

The core ships with XCTest coverage (`Tests/PkgSenderCoreTests`). The macOS SDK  
in a Command Line Tools–only environment does not include XCTest; run  
`xcodebuild test` from the **full Xcode**.

Known limitations:

- The PS4 GoldHEN path requires Payload Server / BinLoader on the console, and  
  the console must be able to call back to the PC (a firewall or an isolated  
  network yields "injected but never called back").
- After a pause, resuming also has to be confirmed on the console itself — same  
  as upstream.
- A locked screen or a window-less session makes click behaviour impossible to  
  verify with screenshots or automation.
