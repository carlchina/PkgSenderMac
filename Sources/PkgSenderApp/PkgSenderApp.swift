import AppKit
import SwiftUI

@main
struct PkgSenderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("PKG Sender") {
            RootView(model: model)
                // Native title bar (THEME.md: no custom chrome on either
                // toolkit) with the dark Aqua appearance the palette implies.
                .frame(minWidth: 1140, minHeight: 560)
                .background(Theme.bg)
                .environmentObject(model)
                .environmentObject(L10n.shared)
                .onAppear { model.start() }
        }
        .windowStyle(.titleBar)
        .commands { PkgSenderCommands(model: model) }
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.activate(ignoringOtherApps: true)
        // SwiftUI on macOS automatically focuses the first focusable control
        // (usually the PS IP text field). Clear first responder after launch so
        // no text field keeps the caret unless the user deliberately clicks it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            for window in NSApp.windows {
                window.makeFirstResponder(nil)
            }
        }
    }

    /// Closing the last window quits — the LAN server and the queue live in
    /// the app, not in a document window.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Nothing to tear down explicitly: `RangeHTTPServer.stop()` runs on
        // deinit and the PC announce task is cancelled with its actor.
    }
}

// MARK: - Menu commands

/// Menu items and their shortcuts, on top of the standard Edit/Window menus.
///
/// `@MainActor` so it can read the shared `L10n` (also main-actor isolated)
/// directly. Language changes repaint the menu because every command action
/// calls `model.relocalize()`, which republishes the model's display strings.
@MainActor
struct PkgSenderCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(L10n.shared.t("menu.about")) { model.showAbout() }
            Button(L10n.shared.t("menu.checkUpdate")) { Task { await model.checkForUpdate() } }
        }
        CommandMenu(L10n.shared.t("menu.library")) {
            Button(L10n.shared.t("menu.scanDrives")) { model.addDrives() }
                .keyboardShortcut("D", modifiers: .command)
            Button(L10n.shared.t("menu.addFolder")) { model.addFolder() }
                .keyboardShortcut("O", modifiers: .command)
            Button(L10n.shared.t("menu.scan")) { model.scanButton() }
                .keyboardShortcut("R", modifiers: .command)
            Divider()
            Button(L10n.shared.t("menu.selectNone")) { model.clearSelection() }
                .keyboardShortcut(".", modifiers: .command)
            Button(L10n.shared.t("menu.selectAll")) { model.selectAll() }
                .keyboardShortcut("A", modifiers: .command)
            Button(L10n.shared.t("menu.invertSelection")) { model.invertSelection() }
                .keyboardShortcut("I", modifiers: [.command, .shift])
        }
        CommandMenu(L10n.shared.t("menu.transfer")) {
            Button(L10n.shared.t("menu.sendPkg")) { model.enqueueSelection() }
                .keyboardShortcut("S", modifiers: .command)
                .disabled(!model.hasPkgSelection)
            Button(L10n.shared.t("menu.copyImages")) { model.copySelection() }
                .keyboardShortcut("I", modifiers: .command)
                .disabled(!model.hasImageSelection)
            Divider()
            Button(model.pauseAllLabel) { model.togglePauseAll() }
                .keyboardShortcut("P", modifiers: .command)
            Button(L10n.shared.t("menu.clearDone")) { model.clearDone() }
                .keyboardShortcut("K", modifiers: .command)
        }
        CommandMenu(L10n.shared.t("menu.console")) {
            Button(L10n.shared.t("menu.testConnection")) { Task { await model.testConnection() } }
                .keyboardShortcut("T", modifiers: .command)
            Button(L10n.shared.t("menu.detectConsole")) { Task { await model.autoDetect() } }
                .keyboardShortcut("L", modifiers: .command)
            Divider()
            Button(model.shared ? L10n.shared.t("menu.stopSharing") : L10n.shared.t("menu.shareToConsole")) { model.toggleShare() }
                .keyboardShortcut("H", modifiers: .command)
            Divider()
            Toggle(L10n.shared.t("menu.ps4Sequential"), isOn: $model.sequentialMode)
        }
        CommandMenu(L10n.shared.t("menu.view")) {
            Toggle(L10n.shared.t("menu.compact"), isOn: $model.compact)
                .keyboardShortcut("0", modifiers: .command)
            Toggle(L10n.shared.t("menu.hideDlc"), isOn: $model.hideExtras)
                .keyboardShortcut("E", modifiers: [.command, .shift])
            Button(L10n.shared.t("menu.clearSearch")) { model.clearSearch() }
                .keyboardShortcut("F", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .help) {
            Button(L10n.shared.t("menu.guide")) { model.showGuide() }
                .keyboardShortcut("/", modifiers: .command)
        }
        CommandMenu(L10n.shared.t("lang.menu")) {
            Button((L10n.shared.followsSystem ? "✓ " : "") + L10n.shared.t("lang.system")) {
                L10n.shared.select(nil)
                model.relocalize()
            }
            Divider()
            ForEach(L10n.available) { lang in
                Button((L10n.shared.languageCode == lang.code ? "✓ " : "") + lang.nativeName) {
                    L10n.shared.select(lang.code)
                    model.relocalize()
                }
            }
        }
    }
}
