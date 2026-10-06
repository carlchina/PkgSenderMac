import AppKit
import PkgSenderCore
import SwiftUI

// MARK: - Card

/// One library card: cover, title, meta line, badges and the family chip.
///
/// PS5 covers get the rounded 16pt art treatment, PS4 the flat one — same as
/// the upstream `Ps5ImageBackgroundConverter`.
struct GameCard: View {
    let item: GameItem
    let isSelected: Bool
    let icon: Data?
    let onSelect: (Bool, Bool) -> Void      // (command, shift)
    let onOpen: () -> Void
    let onFamily: () -> Void

    /// Decoded cover art, kept across body evaluations.
    ///
    /// Keyed by the icon bytes themselves so a re-scan that changes the art
    /// still refreshes it, while ordinary re-renders (selection, hover, a
    /// sibling card changing) reuse the already-decoded image.
    @State private var iconCache: (bytes: Data, image: NSImage)?

    private var decodedIcon: NSImage? {
        guard let icon, !icon.isEmpty else { return nil }
        if let cache = iconCache, cache.bytes == icon { return cache.image }
        guard let image = NSImage(data: icon) else { return nil }
        iconCache = (icon, image)
        return image
    }

    var body: some View {
        VStack(spacing: 6) {
            cover
            Text(item.title)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(Theme.text)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(item.meta)
                .font(.system(size: 11))
                .foregroundColor(Theme.muted)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            badges
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(Theme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Theme.accent : Theme.card2,
                              lineWidth: isSelected ? 2 : 1)
                // Inset by half the stroke so the 2px selected border is drawn
                // fully inside the card and never clipped by the grid cell.
                .padding(isSelected ? -1 : 0)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        // Selection must feel instant, so a plain click acts immediately and
        // the double-click-to-send is layered on top.
        //
        // The obvious alternative — `TapGesture(count: 2).exclusively(before:
        // TapGesture(count: 1))` — makes every single click wait out the
        // double-click disambiguation window (~0.3–0.45 s) before the selection
        // is applied. That is exactly the "click feels sluggish" symptom.
        //
        // Two earlier bugs are avoided here as well:
        //  1. `onTapGesture(count: 1)` and `count: 2` on the same view cannot
        //     coexist — the later mount replaces the earlier one.
        //  2. Modifier-specific `TapGesture().modifiers(...)` handlers fire in
        //     addition to a plain-click branch that ignores modifiers, so a
        //     shift-click ran a plain click first and lost the range.
        // Now the modifiers are sampled once on mouse-down and the single
        // gesture branches on them.
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    // Latch modifiers at mouse-down: by mouse-up the keys may
                    // already be released. Write only on change, otherwise
                    // every pointer movement invalidates the card.
                    let f = NSEvent.modifierFlags
                    let fresh = (f.contains(.command), f.contains(.shift))
                    if fresh != clickFlags { clickFlags = fresh }
                }
                .onEnded { _ in
                    onSelect(clickFlags.command, clickFlags.shift)
                    clickFlags = (false, false)
                }
        )
        // Double-click to send. `exclusive` double-taps, so a second click
        // during the window re-selects (cheap) and then sends once.
        .onTapGesture(count: 2) {
            let f = NSEvent.modifierFlags
            if !f.contains(.command), !f.contains(.shift) { onOpen() }
        }
        .help(helpText)
    }

    /// Modifiers as held when the current click started. Sampled on mouse-down
    /// because by mouse-up the keys may already be released.
    @State private var clickFlags: (command: Bool, shift: Bool) = (false, false)

    private var helpText: String {
        item.familyTip.isEmpty ? item.path : item.familyTip
    }

    /// Square cover that scales with the column width, so cards keep the
    /// reference's proportions instead of a fixed-height letterbox.
    ///
    /// The decoded `NSImage` is cached: `NSImage(data:)` re-decodes the PNG on
    /// every single body evaluation, and a grid of cards re-evaluates whenever
    /// any one of them changes, so decoding here made selection feel sluggish.
    private var cover: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Theme.card2)
            if let image = decodedIcon {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text("📦")
                    .font(.system(size: 44))
                    .opacity(0.45)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var badges: some View {
        HStack(alignment: .center, spacing: 5) {
            // Badges keep their intrinsic size (never wrap); the row as a whole
            // is clipped to the card so a wide set of badges can never widen
            // the grid cell and clip the selection border. Padding and spacing
            // are tightened (7 / 5) so the size label fits without truncating.
            HStack(spacing: 5) {
                if item.isPS5 {
                    Badge(text: "PS5", background: Theme.text, foreground: Theme.bg)
                }
                if item.isPS4 {
                    Badge(text: "PS4", background: Theme.ps4Blue, foreground: .white)
                }
                if item.isDLC {
                    Badge(text: "DLC", background: Theme.amber, foreground: Theme.bg)
                }
                if item.role == .image {
                    Badge(text: item.format.uppercased(),
                          background: formatColor,
                          foreground: .white)
                }
                if item.hasFamily {
                    BadgeButton(text: "🔗×\(item.familyCount)",
                                background: Theme.ghost,
                                foreground: Theme.text,
                                help: item.familyTip) { onFamily() }
                }
            }
            .lineLimit(1)
            .fixedSize()
            Spacer(minLength: 3)
            Text(item.sizeText)
                .font(.system(size: 11))
                .foregroundColor(Theme.muted)
                .lineLimit(1)
                .fixedSize()
                // The size is the payload here: give it layout priority so the
                // Spacer yields first instead of squeezing it to an ellipsis.
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    private var formatColor: Color {
        switch item.format.lowercased() {
        case "ffpkg": return Color(hex: 0x9B6DDB)
        // exfat and ffpfsc share the amber chip, as in the reference UI.
        default: return Theme.amber
        }
    }
}

// MARK: - Panel

/// The games grid: adaptive columns (150pt minimum) so cards always fill the
/// row, with empty / loading / error states around it.
struct LibraryPanel: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject private var l10n: L10n

    var body: some View {
        VStack(spacing: 8) {
            if model.isFiltering { filterBanner }
            Text(model.gamesLabel)
                .font(.system(size: 12))
                .foregroundColor(Theme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 4)
                .help(l10n.t("library.selectHelp"))
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .panel()
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            LibraryStateView(symbol: " hourglass",
                             title: l10n.t("library.state.scanning"),
                             detail: model.status)
        case .error(let message):
            LibraryStateView(symbol: "exclamationmark.triangle",
                             title: l10n.t("library.state.title"),
                             detail: message)
        case .empty(let message):
            LibraryStateView(symbol: "square.stack.3d.up",
                             title: l10n.t("library.noGamesYet"),
                             detail: message)
        case .loaded:
            grid
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 10)], spacing: 10) {
                ForEach(model.games) { item in
                    GameCard(
                        item: item,
                        isSelected: model.selection.contains(item.id),
                        icon: model.icon(for: item),
                        onSelect: { command, shift in
                            model.select(id: item.id, command: command, shift: shift)
                        },
                        onOpen: { openItem(item) },
                        onFamily: { model.toggleFamily(item.familyKey) }
                    )
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filterBanner: some View {
        HStack(spacing: 8) {
            Text(model.filterLabel)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(Theme.bannerText)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(l10n.t("library.showAll")) { model.clearSearch() }
                .buttonStyle(ThemeButtonStyle(accent: false))
                .help(l10n.t("library.showAllHelp"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bannerBg))
        .overlay(
            RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.accent, lineWidth: 1)
        )
    }

    /// Double-click: send the PKGs. When the double-clicked card is part of the
    /// current selection, the whole selection goes — that is what multi-select
    /// is for. Otherwise just that one card. Images still copy to /data/homebrew.
    private func openItem(_ item: GameItem) {
        if item.role == .image {
            Task { await model.copyImages([item]) }
            return
        }
        let picked = model.selection.contains(item.id)
            ? model.games.filter { model.selection.contains($0.id) }
            : [item]
        model.enqueue(picked)
    }
}

struct LibraryStateView: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            Image(systemName: symbol)
                .font(.system(size: 34))
                .foregroundColor(Theme.muted)
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(Theme.text)
            Text(detail)
                .font(.system(size: 11))
                .foregroundColor(Theme.muted)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}

// MARK: - Icon lookup
//
// `AppModel.icon(for:)` lives in AppModel.swift — it reads the private
// `library` box, so an extension in this file cannot reach it.
