import AppKit
import PkgSenderCore
import SwiftUI
import UniformTypeIdentifiers

/// The whole window: header, two-row toolbar, library + queue, status bar.
struct RootView: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject private var l10n: L10n
    @State private var window: NSWindow?
    @State private var savedSize = CGSize(width: 1200, height: 700)

    /// Map an internal filter/sort value ("PS5", "Size ↓", …) to its
    /// localised label while keeping the binding on the raw value.
    private func optionLabel(_ value: String) -> String {
        switch value {
        case "All": return l10n.t("platform.all")
        case "PS5": return l10n.t("platform.ps5")
        case "PS4": return l10n.t("platform.ps4")
        case "Name": return l10n.t("sort.name")
        case "Size ↓": return l10n.t("sort.sizeDown")
        case "Size ↑": return l10n.t("sort.sizeUp")
        default: return value
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.compact {
                compactBar
            } else {
                headerBar
                toolbarBar
            }
            bodyRow.layoutPriority(1)
            if !model.compact { statusBar.frame(height: 36) }
        }
        .frame(minWidth: model.compact ? 360 : 1140,
               maxWidth: .infinity,
               minHeight: model.compact ? 240 : 560,
               maxHeight: .infinity)
        .background(Theme.bg)
        .background(WindowAccessor { window = $0 })
        .onChange(of: model.compact) { applyCompact($0) }
        .onChange(of: model.search) { _ in model.scheduleFilter(debounce: true) }
        .onChange(of: model.platformFilter) { _ in model.scheduleFilter(debounce: false) }
        .onChange(of: model.sortMode) { _ in model.scheduleFilter(debounce: false) }
        .onChange(of: model.hideExtras) { _ in model.scheduleFilter(debounce: false) }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            model.handleDrop(providers: providers)
        }
        .sheet(item: $model.sheet) { item in
            sheetView(item)
        }
    }

    // MARK: - Compact bar

    private var compactBar: some View {
        HStack(spacing: 12) {
            Text(model.dotText)
                .font(.system(size: 12))
                .foregroundColor(Theme.text)
                .lineLimit(1)
            // Speed / ETA are empty until a transfer starts; showing empty
            // labels just leaves gaps in the bar.
            if !model.speedText.isEmpty {
                Text(model.speedText)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Theme.green)
                    .lineLimit(1)
            }
            if !model.etaText.isEmpty {
                Text(model.etaText)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Theme.accent)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(l10n.t("queue.title"))
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(Theme.muted)
                .lineLimit(1)
            Button(l10n.t("compact.expand")) { model.compact = false }
                .buttonStyle(ThemeButtonStyle(accent: false))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.card)
        .overlay(Divider().background(Theme.card2), alignment: .bottom)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9).fill(Theme.accent)
                    if let logo = AppAssets.logo() {
                        Image(nsImage: logo)
                            .resizable()
                            .scaledToFit()
                    }
                }
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 1) {
                    Text("PKG Sender")
                        .font(Theme.title())
                        .foregroundColor(Theme.text)
                    Text(l10n.t("header.subtitle"))
                        .font(.system(size: 11))
                        .foregroundColor(Theme.muted)
                }
            }
            Spacer(minLength: 8)
            // Explicitly trailing-aligned: the status text below carries a
            // `maxWidth`, which otherwise makes this group stop short of the
            // right edge instead of hugging it.
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Text("PS")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Theme.muted)
                    // No focus plumbing: the IP field must not steal first
                    // responder on launch, and clicking a card should hand the
                    // caret away. `ThemeTextField` deliberately does not force
                    // focus, so the only way to get the caret here is a
                    // deliberate click.
                    ThemeTextField(placeholder: l10n.t("header.consoleIp"),
                                   text: $model.psIP, width: 120)
                    Button(l10n.t("header.test")) { Task { await model.testConnection() } }
                        .buttonStyle(ThemeButtonStyle())
                        .frame(minWidth: 64)
                    Button(l10n.t("header.detect")) { Task { await model.autoDetect() } }
                        .buttonStyle(ThemeButtonStyle())
                        .help(l10n.t("header.dotHelp"))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.card2))

                HStack(spacing: 6) {
                    Text(l10n.t("header.pc"))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Theme.muted)
                    pcPicker
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.card2))

                Rectangle()
                    .fill(Theme.card2)
                    .frame(width: 1, height: 24)

                Text(model.dotText)
                    .font(.system(size: 11))
                    .foregroundColor(dotColor)
                    .lineLimit(1)
                    .fixedSize()
            }
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.card)
    }

    private var pcPicker: some View {
        Menu {
            ForEach(model.pcOptions, id: \.address) { network in
                Button(model.label(for: network)) { model.selectPC(network) }
            }
        } label: {
            HStack(spacing: 6) {
                Text(model.pcIP.isEmpty ? l10n.t("header.noLanAddress") : model.pcIP)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
                    .foregroundColor(Theme.muted)
            }
        }
        .menuStyle(.borderlessButton)
        .frame(width: 150)
        .help(l10n.t("header.pcHelp"))
    }

    private var dotColor: Color {
        switch model.dot {
        case .ok: return Theme.green
        case .bad: return Theme.red
        case .warn: return Theme.accent
        case .none: return Theme.muted
        }
    }

    // MARK: - Toolbar

    private var toolbarBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(l10n.t("toolbar.addFolder")) { model.addFolder() }
                    .buttonStyle(ThemeButtonStyle(accent: true))
                    .frame(minWidth: 120)
                    .help(l10n.t("toolbar.addFolderHelp"))
                Button(l10n.t("toolbar.scan")) { model.scanButton() }
                    .buttonStyle(ThemeButtonStyle(accent: false))
                    .help(l10n.t("toolbar.scanHelp"))
                Rectangle()
                    .fill(Theme.card2)
                    .frame(width: 1, height: 20)
                    .padding(.horizontal, 8)
                ThemePicker(selection: $model.platformFilter,
                            options: AppModel.platformOptions,
                            label: { optionLabel($0) },
                            width: 110)
                ThemePicker(selection: $model.sortMode,
                            options: AppModel.sortOptions,
                            label: { optionLabel($0) },
                            width: 130)
                    .help(l10n.t("toolbar.sortHelp"))
                ThemeToggle(title: l10n.t("toolbar.hideDlc"), isOn: $model.hideExtras,
                            help: l10n.t("toolbar.hideDlcHelp"))
            }

            HStack(spacing: 8) {
                HStack {
                    ThemeTextField(placeholder: l10n.t("toolbar.searchPlaceholder"), text: $model.search)
                    Button("✕") { model.clearSearch() }
                        .buttonStyle(ThemeButtonStyle(accent: false))
                        .help(l10n.t("toolbar.searchClear"))
                }
                Button(l10n.t("toolbar.sendPkg")) { model.enqueueSelection() }
                    .buttonStyle(ThemeButtonStyle(accent: model.hasPkgSelection))
                    .frame(minWidth: 150)
                    .disabled(!model.hasPkgSelection)
                    .help(l10n.t("toolbar.sendPkgHelp"))
                Button(l10n.t("toolbar.copyImages")) { model.copySelection() }
                    .buttonStyle(ThemeButtonStyle(accent: model.hasImageSelection))
                    .disabled(!model.hasImageSelection)
                    .help(l10n.t("toolbar.copyImagesHelp"))
                Button(model.shareLabel) { model.toggleShare() }
                    .buttonStyle(ThemeButtonStyle(accent: model.shared))
                    .help(l10n.t("toolbar.shareHelp"))
                Button(model.pauseAllLabel) { model.togglePauseAll() }
                    .buttonStyle(ThemeButtonStyle(accent: false))
                    .help(l10n.t("toolbar.pauseAllHelp"))
                Button(l10n.t("menu.clearDone")) { model.clearDone() }
                    .buttonStyle(ThemeButtonStyle())
                    .help(l10n.t("toolbar.clearDoneHelp"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.card)
        .overlay(Divider().background(Theme.card2), alignment: .bottom)
    }

    // MARK: - Body

    private var bodyRow: some View {
        HStack(spacing: 12) {
            if !model.compact {
                LibraryPanel(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                QueuePanel(model: model)
                    .frame(width: 360)
                    .frame(maxHeight: .infinity)
            } else {
                // Compact: the queue is the whole window, so let it fill the
                // width instead of leaving empty margins beside a 360pt column.
                QueuePanel(model: model, showsCompactToggle: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Theme.accent)
                .frame(width: 4)
                .padding(.vertical, 4)
                .cornerRadius(2)
            Text(model.status)
                .font(.system(size: 11))
                .foregroundColor(Theme.text)
                .lineLimit(1)
                .padding(.leading, 10)
            Spacer(minLength: 8)
            Text(model.speedText)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Theme.green)
                .lineLimit(1)
                .padding(.leading, 12)
            Button(l10n.t("statusbar.guide")) { model.showGuide() }
                .buttonStyle(ThemeButtonStyle(accent: false))
                .padding(.leading, 8)
                .help(l10n.t("statusbar.guideHelp"))
            if model.updateAvailable {
                Button(l10n.t("statusbar.update")) { model.openUpdate() }
                    .buttonStyle(ThemeButtonStyle(accent: true))
                    .padding(.leading, 8)
                    .help(l10n.t("statusbar.updateHelp"))
            }
            Button(l10n.t("statusbar.about")) { model.showAbout() }
                .buttonStyle(ThemeButtonStyle())
                .padding(.leading, 8)
                .help(l10n.t("statusbar.aboutHelp"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.card)
        .overlay(Divider().background(Theme.card2), alignment: .top)
    }

    // MARK: - Compact window sizing

    /// Compact view (like pkg-viewer): the app shrinks to a small window
    /// showing only connection status + ETA + the send queue.
    private func applyCompact(_ on: Bool) {
        guard let window else { return }
        if on {
            savedSize = window.frame.size
            window.minSize = CGSize(width: 360, height: 240)
            window.setFrame(NSRect(x: window.frame.origin.x,
                                   y: window.frame.origin.y,
                                   width: 470, height: 520),
                            display: true, animate: false)
        } else {
            window.minSize = CGSize(width: 1140, height: 560)
            // Restore after the expand layout settles: resizing in the same
            // tick as the visibility changes sometimes gets swallowed.
            DispatchQueue.main.async {
                window.minSize = CGSize(width: 1140, height: 560)
                let width = max(savedSize.width, 1140)
                let height = max(savedSize.height, 560)
                window.setFrame(NSRect(x: window.frame.origin.x,
                                       y: window.frame.origin.y,
                                       width: width, height: height),
                                display: true, animate: false)
            }
        }
    }

    // MARK: - Sheets

    @ViewBuilder
    private func sheetView(_ item: SheetItem) -> some View {
        switch item {
        case .about:
            AboutDialog(model: model)
        case .guide:
            GuideDialog(model: model)
        case .switchConsole(let prompt):
            SwitchDialog(prompt: prompt) { model.resolveSwitch($0) }
        case .copyChoice(let prompt):
            CopyChoiceDialog(prompt: prompt) { model.resolveCopy($0) }
        }
    }
}
