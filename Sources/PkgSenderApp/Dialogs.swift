import AppKit
import SwiftUI

// MARK: - About

struct AboutDialog: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject private var l10n: L10n
    @State private var receiverPath: String? = AppAssets.receiverPath()

    var body: some View {
        VStack(spacing: 4) {
            if let image = AppAssets.aboutImage() {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 190)
            }
            Text(l10n.t("about.title", UpdateService.appVersion))
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(Theme.text)
                .padding(.top, 8)
            Text("macOS 移植版：CarlChina")
                .font(.system(size: 12))
                .foregroundColor(Theme.muted)
            Text("by Loopayeh")
                .font(.system(size: 12))
                .foregroundColor(Theme.muted)
            Text(l10n.t("about.tagline"))
                .font(.system(size: 12))
                .foregroundColor(Theme.text)
                .padding(.top, 8)

            ThemeToggle(title: l10n.t("about.launchAtLogin"),
                        isOn: Binding(
                            get: { model.launchAtLogin },
                            set: { model.setLaunchAtLogin($0) }
                        ),
                        help: l10n.t("about.launchHelp"))
            .padding(.top, 10)

            ThemeToggle(title: l10n.t("about.autoUpdate"),
                        isOn: Binding(
                            get: { model.updateCheck },
                            set: { model.setUpdateCheck($0) }
                        ),
                        help: l10n.t("about.autoUpdateHelp"))
            .padding(.top, 10)

            updateSection

            receiverLine

            Button(l10n.t("about.close")) { model.closeAbout() }
                .buttonStyle(ThemeButtonStyle())
                .frame(minWidth: 120)
                .padding(.top, 10)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(width: 420)
        .background(Theme.card)
    }

    /// Where the receiver ELF ships, plus a shortcut to reveal it in Finder.
    @ViewBuilder
    private var receiverLine: some View {
        if let path = receiverPath {
            VStack(spacing: 4) {
                Text("pkg-receiver.elf")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Theme.text)
                Text(path)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.muted)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Button(l10n.t("about.showResources")) { AppAssets.reveal(path) }
                    .buttonStyle(ThemeButtonStyle(accent: false))
            }
            .padding(.top, 6)
        }
    }

    /// Version line, a manual "Check now" button, and — when a newer release
    /// is found — an "Update available" banner that opens the release page.
    @ViewBuilder
    private var updateSection: some View {
        VStack(spacing: 6) {
            Divider().background(Theme.card2)
            HStack(spacing: 8) {
                Text(l10n.t("about.version"))
                    .font(.system(size: 12))
                    .foregroundColor(Theme.muted)
                Text(UpdateService.appVersion)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Theme.text)
                Spacer(minLength: 8)
                if model.updateChecking {
                    ProgressView()
                        .scaleEffect(0.6)
                        .padding(.trailing, 4)
                }
                Button(l10n.t("about.checkUpdate")) { Task { await model.checkForUpdate() } }
                    .buttonStyle(ThemeButtonStyle(accent: false))
                    .disabled(model.updateChecking)
            }
            if model.updateAvailable {
                HStack(spacing: 8) {
                    Text(l10n.t("about.updateAvailable", model.updateLatestVersion))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Theme.amber)
                    Spacer(minLength: 8)
                    Button(l10n.t("about.viewUpdate")) { model.openUpdate() }
                        .buttonStyle(ThemeButtonStyle())
                }
            } else if !model.updateChecking {
                Text(l10n.t("about.upToDate"))
                    .font(.system(size: 11))
                    .foregroundColor(Theme.muted)
            }
        }
        .padding(.top, 6)
    }
}

// MARK: - Guide

struct GuideDialog: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject private var l10n: L10n
    @State private var receiverPath: String? = AppAssets.receiverPath()

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(l10n.t("guide.title"))
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(Theme.text)
                    step(l10n.t("guide.step1"))
                    step(l10n.t("guide.step2"))
                    step(l10n.t("guide.step3"))
                    step(l10n.t("guide.step4"))
                    step(l10n.t("guide.step5"))
                    step(l10n.t("guide.step6"))

                    Text(l10n.t("guide.lanTitle"))
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(Theme.text)
                        .padding(.top, 8)
                    step(l10n.t("guide.lanIntro"))

                    Text(l10n.t("guide.method1Title"))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(Theme.text)
                    step(l10n.t("guide.method1"))

                    Text(l10n.t("guide.method2Title"))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(Theme.text)
                    step(l10n.t("guide.method2"))
                    mono(l10n.t("guide.method2diagram"))
                    step(l10n.t("guide.method2step1"))
                    step(l10n.t("guide.method2step2"))
                    step(l10n.t("guide.method2step3"))
                    warning(l10n.t("guide.directCableWarn"))

                    Text(l10n.t("guide.ps4TipTitle"))
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(Theme.text)
                        .padding(.top, 8)
                    step(l10n.t("guide.ps4Tip"))

                    Text(l10n.t("guide.troubleTitle"))
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(Theme.text)
                        .padding(.top, 8)
                    step(l10n.t("guide.trouble.noReceiver"))
                    step(l10n.t("guide.trouble.noAdapter"))
                    step(l10n.t("guide.trouble.pushNoStart"))
                    step(l10n.t("guide.trouble.ipChanges"))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if let path = receiverPath {
                    Button(l10n.t("about.showResources")) { AppAssets.reveal(path) }
                        .buttonStyle(ThemeButtonStyle(accent: false))
                }
                Spacer(minLength: 8)
                Button(l10n.t("guide.close")) { close() }
                    .buttonStyle(ThemeButtonStyle())
                    .frame(minWidth: 120)
            }
            .padding(.top, 12)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(width: 520, height: 600)
        .background(Theme.card)
    }

    private func step(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func mono(_ text: String) -> Text {
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .foregroundColor(Theme.muted)
    }

    private func warning(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(Theme.amber)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func close() {
        model.sheet = nil
    }
}

// MARK: - Switch console

struct SwitchDialog: View {
    let prompt: SwitchPrompt
    let onResolve: (Bool) -> Void
    @EnvironmentObject private var l10n: L10n

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(l10n.t("switch.title"))
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(l10n.t("switch.detail", prompt.from, prompt.address, prompt.source))
                .font(.system(size: 12))
                .foregroundColor(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Text(l10n.t("switch.question"))
                .font(.system(size: 12))
                .foregroundColor(Theme.text)
            HStack {
                Spacer(minLength: 8)
                Button(l10n.t("switch.keepMine")) { onResolve(false) }
                    .buttonStyle(ThemeButtonStyle())
                    .frame(minWidth: 100)
                Button(l10n.t("switch.switch")) { onResolve(true) }
                    .buttonStyle(ThemeButtonStyle())
                    .frame(minWidth: 100)
            }
            .padding(.top, 8)
        }
        .padding(24)
        .frame(width: 400)
        .background(Theme.card)
    }
}

// MARK: - Copy choice

/// Resume a partial console file, overwrite it, or cancel.
struct CopyChoiceDialog: View {
    let prompt: CopyPrompt
    let onResolve: (CopyChoice) -> Void
    @EnvironmentObject private var l10n: L10n

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(prompt.complete ? l10n.t("copy.titleComplete") : l10n.t("copy.titleExists"))
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(Theme.text)
            Text("\(prompt.fileName)\nOn console: \(prompt.remoteText) / local: \(prompt.localText).")
                .font(.system(size: 12))
                .foregroundColor(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer(minLength: 8)
                Button(l10n.t("copy.cancel")) { onResolve(.cancel) }
                    .buttonStyle(ThemeButtonStyle(accent: false))
                    .frame(minWidth: 100)
                if prompt.canResume {
                    Button(l10n.t("copy.resume")) { onResolve(.resume) }
                        .buttonStyle(ThemeButtonStyle(accent: false))
                        .frame(minWidth: 100)
                }
                Button(l10n.t("copy.overwrite")) { onResolve(.overwrite) }
                    .buttonStyle(ThemeButtonStyle())
                    .frame(minWidth: 110)
            }
            .padding(.top, 6)
        }
        .padding(24)
        .frame(width: 400)
        .background(Theme.card)
    }
}
