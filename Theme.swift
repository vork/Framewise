import SwiftUI

// MARK: - Theme
//
// Visual language adapted from the sibling project Pixelwise
// (https://github.com/vork/Pixelwise): a near-black, faintly purple canvas with
// a signature purple→amber brand gradient, soft panel surfaces, and a single
// purple accent for selected / active chrome. The A/B side identity stays blue
// (A) / amber (B) so it never collides with the purple UI accent.

enum Theme {
    // ── Surfaces ────────────────────────────────────────────────────────────
    static let bg     = Color(hex: 0x0B0B0F)   // window canvas
    static let panel  = Color(hex: 0x16161E)   // bars, popovers
    static let panel2 = Color(hex: 0x1D1D28)   // insets, control fills
    static let border = Color(hex: 0x262633)   // hairlines

    // ── Text ────────────────────────────────────────────────────────────────
    static let text  = Color(hex: 0xE9E6FF)
    static let muted = Color(hex: 0x8B87A8)

    // ── Brand accents ───────────────────────────────────────────────────────
    static let accentA = Color(hex: 0xDD86FF)  // purple — primary UI accent
    static let accentB = Color(hex: 0xF7A543)  // amber

    // ── Status ──────────────────────────────────────────────────────────────
    static let ok   = Color(hex: 0x7EF7C0)
    static let warn = Color(hex: 0xF7D97E)
    static let err  = Color(hex: 0xFF7B8A)

    // ── A/B side identity ─────────────────────────────────────────────────
    // Tied to the brand gradient endpoints: A = purple, B = amber. Side A
    // therefore shares the purple UI accent — intentional, for a tight match.
    static let sideA = accentA                 // purple
    static let sideB = accentB                 // amber

    // ── Gradients ───────────────────────────────────────────────────────────
    /// The signature 135° purple→amber wash used on primary buttons and accents.
    static let brand = LinearGradient(
        colors: [accentA, accentB],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    /// A low-opacity version of the brand wash for "active" / selected fills,
    /// mirroring Pixelwise's segmented-control active state.
    static let brandSubtle = LinearGradient(
        colors: [accentA.opacity(0.22), accentB.opacity(0.22)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Vertical sheen for bars and panels — a hair lighter at the top edge.
    static let panelSheen = LinearGradient(
        colors: [Color(hex: 0x1B1B25), Color(hex: 0x121219)],
        startPoint: .top, endPoint: .bottom)
}

// MARK: - Color(hex:)

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8)  & 0xFF) / 255.0,
            blue:  Double( hex        & 0xFF) / 255.0,
            opacity: opacity)
    }
}

// MARK: - Primary (gradient) button

/// Filled purple→amber button with a soft brand glow that warms on hover and a
/// subtle press depression. Used for the headline calls-to-action.
struct BrandButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 7

    func makeBody(configuration: Configuration) -> some View {
        Body(configuration: configuration, cornerRadius: cornerRadius)
    }

    private struct Body: View {
        let configuration: ButtonStyleConfiguration
        let cornerRadius: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(Theme.bg)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Theme.brand, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
                )
                .shadow(color: Theme.accentA.opacity(isEnabled ? (hovering ? 0.50 : 0.28) : 0),
                        radius: hovering ? 14 : 8, y: 2)
                .brightness(configuration.isPressed ? -0.06 : (hovering ? 0.05 : 0))
                .saturation(isEnabled ? 1 : 0.25)
                .opacity(isEnabled ? 1 : 0.5)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
                .onHover { hovering = isEnabled && $0 }
                .animation(.easeOut(duration: 0.13), value: hovering)
                .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
        }
    }
}

// MARK: - Ghost (bordered) button

/// Bordered panel button that lights its edge purple on hover. When `active` is
/// true it carries the subtle brand wash + purple edge to read as "on".
struct GhostButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 6
    var active: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        Body(configuration: configuration, cornerRadius: cornerRadius, active: active)
    }

    private struct Body: View {
        let configuration: ButtonStyleConfiguration
        let cornerRadius: CGFloat
        let active: Bool
        @State private var hovering = false

        private var fill: AnyShapeStyle {
            active ? AnyShapeStyle(Theme.brandSubtle) : AnyShapeStyle(Theme.panel2)
        }
        private var edge: Color {
            if active { return Theme.accentA.opacity(0.60) }
            return hovering ? Theme.accentA.opacity(0.55) : Theme.border
        }

        var body: some View {
            configuration.label
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: cornerRadius).fill(fill))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(edge, lineWidth: 1)
                )
                .opacity(configuration.isPressed ? 0.8 : 1)
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.13), value: hovering)
        }
    }
}

// MARK: - Icon button

/// Transparent by default; grows a faint panel pill with a purple edge on hover.
/// Keeps the dense transport row calm until the cursor lands on a control.
struct IconButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 6

    func makeBody(configuration: Configuration) -> some View {
        Body(configuration: configuration, cornerRadius: cornerRadius)
    }

    private struct Body: View {
        let configuration: ButtonStyleConfiguration
        let cornerRadius: CGFloat
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(hovering ? AnyShapeStyle(Theme.panel2) : AnyShapeStyle(Color.clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(hovering ? Theme.accentA.opacity(0.45) : Color.clear, lineWidth: 1)
                )
                .opacity(configuration.isPressed ? 0.6 : 1)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}
