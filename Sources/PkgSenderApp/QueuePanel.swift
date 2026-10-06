import AppKit
import PkgSenderCore
import SwiftUI

/// Right-hand column: the send queue. In compact mode this is the whole
/// window, so it fills the available width and hides the redundant
/// "Compact" checkbox (the compact bar's Expand button already leaves it).
struct QueuePanel: View {
    @ObservedObject var model: AppModel
    var showsCompactToggle: Bool = true
    @EnvironmentObject private var l10n: L10n

    var body: some View {
        VStack(spacing: 8) {
            header
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(model.queue) { entry in
                        QueueRow(entry: entry, icon: model.icon(for: entry.game)) { action in
                            perform(action, on: entry.id)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .padding(12)
        // In compact mode this panel is the whole window and the user can
        // widen it freely. Cap the column so rows stay readable instead of
        // stretching the title and buttons to opposite edges.
        .frame(maxWidth: showsCompactToggle ? .infinity : 520, alignment: .top)
        .frame(maxHeight: .infinity)
        .panel()
    }

    /// Title and the switches share one line, as in the reference UI. The
    /// Compact toggle is dropped in compact mode — it is already on, and the
    /// top bar's Expand button is how you turn it off.
    private var header: some View {
        HStack(spacing: 10) {
            Text(l10n.t("queue.title"))
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(Theme.text)
            Spacer(minLength: 0)
            if showsCompactToggle {
                ThemeToggle(title: l10n.t("queue.compact"), isOn: $model.compact,
                            help: l10n.t("queue.compactHelp"))
            }
            ThemeToggle(title: l10n.t("queue.ps4console"), isOn: $model.sequentialMode,
                        help: l10n.t("queue.ps4consoleHelp"))
        }
    }

    private var footer: some View {
        VStack(spacing: 6) {
            Text(model.queueLabel)
                .font(.system(size: 11))
                .foregroundColor(Theme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
            Bar(value: model.totalProgress)
        }
    }

    private func perform(_ action: QueueAction, on rowID: String) {
        switch action {
        case .pause: model.togglePause(rowID)
        case .up: model.moveRow(rowID, by: -1)
        case .down: model.moveRow(rowID, by: 1)
        case .remove: model.removeRow(rowID)
        case .retry: model.resendRow(rowID)
        }
    }
}

enum QueueAction { case pause, up, down, remove, retry }

// MARK: - Row

/// One queued transfer: cover, state line, message, bar and its controls.
struct QueueRow: View {
    let entry: QueueEntry
    /// Resolved by the caller via `AppModel.icon(for:)` — DLC and patches
    /// usually ship no icon of their own, so the family's base-game art is
    /// used instead. Passing the raw `entry.game.iconData` here left those rows
    /// showing a 📦 placeholder even though the same items render fine as cards.
    let icon: Data?
    let onAction: (QueueAction) -> Void
    @EnvironmentObject private var l10n: L10n

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.game.title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                    .help(entry.game.title)
                HStack(spacing: 8) {
                    Text(stateText)
                        .font(.system(size: 12))
                        .foregroundColor(stateColor)
                    Spacer(minLength: 0)
                    Text(entry.speed)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Theme.green)
                        .lineLimit(1)
                }
                Text(entry.message)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.message)
                    .lineLimit(2)
                    .help(entry.message)
                Bar(value: entry.percent, color: stateColor, height: 6)
                controls
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(rowBackground))
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Theme.bg)
            if let icon, let image = NSImage(data: icon) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text("📦")
                    .font(.system(size: 20))
                    .opacity(0.45)
            }
        }
        .frame(width: 46, height: 46)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var controls: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            if entry.canPause || entry.isPaused {
                ThemeIconButton(title: entry.pauseGlyph,
                                help: l10n.t("queue.help.pause")) { onAction(.pause) }
            }
            if entry.canReorder {
                ThemeIconButton(title: "▲", help: l10n.t("queue.help.up")) { onAction(.up) }
                ThemeIconButton(title: "▼", help: l10n.t("queue.help.down")) { onAction(.down) }
            }
            ThemeIconButton(
                title: "✕",
                help: l10n.t("queue.help.remove")
            ) { onAction(.remove) }
            if entry.canResend {
                ThemeIconButton(title: l10n.t("queue.retryTitle"), accent: true,
                                help: l10n.t("queue.help.retry")) {
                    onAction(.retry)
                }
            }
        }
    }

    private var rowBackground: Color {
        switch entry.state {
        case .done: return Color(hex: 0x1B2A1E)
        case .failed: return Color(hex: 0x2A1E1E)
        default: return Theme.card2
        }
    }

    private var stateText: String {
        if entry.isPaused { return l10n.t("queue.state.paused") }
        switch entry.state {
        case .queued: return l10n.t("queue.state.queued")
        case .sending: return l10n.t("queue.state.sending")
        case .copying: return l10n.t("queue.state.copying")
        case .done: return l10n.t("queue.state.sent")
        case .failed: return l10n.t("queue.state.failed")
        case .paused: return l10n.t("queue.state.paused")
        case .cancelled: return l10n.t("queue.state.cancelled")
        }
    }

    private var stateColor: Color {
        switch entry.state {
        case .done: return Theme.green
        case .failed: return Theme.red
        case .paused: return Theme.amber
        case .sending, .copying: return Theme.accent
        default: return Theme.muted
        }
    }
}
