import SwiftUI

// MARK: - Design tokens
//
// Mirrors THEME.md (single source of truth shared with PKG Viewer and the
// Avalonia builds). Buttons/inputs radius 4, cards radius 8, no shadows —
// flat surfaces separated by tone only. Text on ACCENT is always BG.

enum Theme {
    /// Window background.
    static let bg = Color(hex: 0x171717)
    /// Cards, header/footer bars, panels.
    static let card = Color(hex: 0x202020)
    /// Inputs, selected rows, sub-panels.
    static let card2 = Color(hex: 0x2A2A2A)
    /// Subtle edge for inputs/pickers sitting on `card2` (needs contrast).
    static let card3 = Color(hex: 0x3A3A3A)
    static let accent = Color(hex: 0x4F8EF7)
    static let accentHover = Color(hex: 0x6FA8FF)
    static let accentPressed = Color(hex: 0x3B70C9)
    static let text = Color(hex: 0xF1F3F8)
    static let muted = Color(hex: 0x8B93A5)

    // Button states (from the viewer's _RBTN_FACE).
    static let ghost = Color(hex: 0x404040)
    static let ghostHover = Color(hex: 0x2C3342)
    static let ghostPressed = Color(hex: 0x333A44)
    static let disabledFace = Color(hex: 0x2A2A2A)

    // Semantic badges — kept as-is, intentionally not normalized.
    static let green = Color(hex: 0x6FCF7B)
    static let amber = Color(hex: 0xE8A34C)
    static let red = Color(hex: 0xE06C5B)
    static let ps4Blue = Color(hex: 0x0070D1)
    static let bannerBg = Color(hex: 0x1E3A5F)
    static let bannerText = Color(hex: 0xBFD6FF)
    static let message = Color(hex: 0xC6CBD8)

    // Typography: Title 18 bold, Body 11–12, Emphasis 12–13 bold,
    // Small 10–11 muted, Badge 11 bold, Button 12 bold.
    static func title() -> Font { .system(size: 18, weight: .bold) }
    static func body(_ size: CGFloat = 12) -> Font { .system(size: size) }
    static func emphasis(_ size: CGFloat = 12) -> Font { .system(size: size, weight: .bold) }
    static func small(_ size: CGFloat = 11) -> Font { .system(size: size) }
    static func badge() -> Font { .system(size: 11, weight: .bold) }
    static func button() -> Font { .system(size: 12, weight: .bold) }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

// MARK: - Button

/// Accent (blue) or ghost (grey) button with the THEME.md state faces.
///
/// A `PrimitiveButtonStyle` rather than a plain `ButtonStyle` so the hover
/// state can live in a real `View` (`@State` inside a style struct does not
/// survive the style being recreated on every body evaluation).
struct ThemeButtonStyle: PrimitiveButtonStyle {
    var accent: Bool = true

    @MainActor func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, accent: accent)
    }

    /// Named `Face` on purpose: a nested type called `Body` would bind the
    /// protocol's `Body` associated type and break the conformance.
    struct Face: View {
        let configuration: Configuration
        let accent: Bool
        @State private var hover = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: accent ? .bold : .regular))
                .foregroundColor(foreground)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 4).fill(face))
                .contentShape(Rectangle())
                .onHover { hover = $0 }
                .onTapGesture { configuration.trigger() }
        }

        private var face: Color {
            guard isEnabled else { return Theme.disabledFace }
            if accent { return hover ? Theme.accentHover : Theme.accent }
            return hover ? Theme.ghostHover : Theme.ghost
        }

        private var foreground: Color {
            isEnabled ? (accent ? Theme.bg : Theme.text) : Theme.muted
        }
    }
}

/// Small icon button used inside queue rows and card chips.
struct ThemeIconButton: View {
    let title: String
    var accent: Bool = false
    var help: String? = nil
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(ThemeButtonStyle(accent: accent))
            .help(help ?? "")
    }
}

// MARK: - Panel

/// Cards radius 8, 1px CARD2 border, flat — no shadows.
struct PanelModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.card2, lineWidth: 1)
            )
    }
}

extension View {
    func panel() -> some View { modifier(PanelModifier()) }
}

// MARK: - Text field

/// CARD2 input with an ACCENT focus border (THEME.md note for Avalonia
/// inputs applies to the native build as well).
struct ThemeTextField: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat? = nil

    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundColor(Theme.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.card2))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(focused ? Theme.accent : Theme.card2, lineWidth: 1)
            )
            .focused($focused)
            .frame(width: width)
    }
}

// MARK: - Popup picker

/// CARD2 popup button standing in for the Avalonia ComboBox.
struct ThemePicker<Value: Hashable>: View {
    var title: String? = nil
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String
    var width: CGFloat? = nil

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button(label(option)) { selection = option }
            }
        } label: {
            // The face is drawn *outside* the Menu below: `borderlessButton`
            // drops any background applied to the label itself.
            HStack(spacing: 6) {
                Text(title.map { "\($0) " } ?? "" + label(selection))
                    .font(.system(size: 12))
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
                    .foregroundColor(Theme.muted)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .menuStyle(.borderlessButton)
        .frame(width: width)
        .fixedSize(horizontal: width == nil, vertical: false)
        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.card2))
        .overlay(
            RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.card3, lineWidth: 1)
        )
    }
}

// MARK: - Checkbox

struct ThemeToggle: View {
    let title: String
    @Binding var isOn: Bool
    var help: String? = nil

    var body: some View {
        Toggle(title, isOn: $isOn)
            .toggleStyle(.checkbox)
            .font(.system(size: 11))
            .foregroundColor(Theme.muted)
            .help(help ?? "")
    }
}

// MARK: - Badge

/// Filled chip (`PS5` / `PS4` / `DLC` / `EXFAT`…) — 11 bold, radius 4.
///
/// `fixedSize()` keeps a chip on one line: inside a narrow card the default
/// layout would otherwise wrap `PS4` into "PS" / "4".
struct Badge: View {
    let text: String
    let background: Color
    let foreground: Color

    var body: some View {
        Text(text)
            .font(Theme.badge())
            .foregroundColor(foreground)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, hPadding)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(background))
    }

    /// 7 instead of 8 in the library card's badge row, where reclaiming a few
    /// points is what lets the size label show in full.
    var hPadding: CGFloat { 7 }
}

/// Clickable variant of `Badge` — identical metrics, so a chip that happens to
/// be a button (e.g. the family/link toggle) lines up with the plain ones
/// instead of rendering taller and stealing width from the size label.
struct BadgeButton: View {
    let text: String
    let background: Color
    let foreground: Color
    var help: String? = nil
    let action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(Theme.badge())
                .foregroundColor(foreground)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(hover ? background.opacity(0.75) : background)
                )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .help(help ?? "")
    }
}

// MARK: - Progress bar

struct Bar: View {
    var value: Double      // 0...1
    var color: Color = Theme.accent
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.card2)
                Capsule()
                    .fill(color)
                    .frame(width: max(0, min(1, value)) * proxy.size.width)
            }
        }
        .frame(height: height)
    }
}
