import AppKit
import SwiftUI

/// Astryx (astryx.atmeta.com) core tokens, neutral theme, translated by hand: Astryx ships CSS
/// variables for the web, not Swift. Values are its light / dark pairs.
enum Astryx {
    enum Color {
        static let body = dynamic(0xF1F1F1, 0x1B1B1B)
        static let card = dynamic(0xFFFFFF, 0x262626)        // --color-background-surface
        static let muted = dynamic(0xF1F1F1, 0x1B1B1B)
        static let accent = dynamic(0x1B1B1B, 0xF1F1F1)
        static let onAccent = dynamic(0xFFFFFF, 0x111111)
        static let textPrimary = dynamic(0x000000, 0xFFFFFF)
        static let textSecondary = dynamic(0x474747, 0x9E9E9E)
        static let textDisabled = dynamic(0x919191, 0x525252)
        static let iconSecondary = dynamic(0x6A6A6A, 0x9E9E9E)
        static let border = dynamic(0x000000, 0xFFFFFF, alpha: (0.08, 0.10))
        static let overlayHover = dynamic(0x000000, 0xFFFFFF, alpha: (0.05, 0.05))
        static let success = dynamic(0x198100, 0x64AF4C)
        static let successMuted = dynamic(0xBCE0BB, 0x90CA90, alpha: (1, 0.24))
        static let textSuccess = dynamic(0x2F7D33, 0x90CA90)
        static let warningMuted = dynamic(0xFAE19E, 0xE2B623, alpha: (1, 0.24))
        static let textWarning = dynamic(0x836700, 0xEEC448)
        static let error = dynamic(0xC9303A, 0xFF705D)
        static let textError = dynamic(0xC0262C, 0xFFAEA7)
        static let errorMuted = dynamic(0xFFC4BE, 0xFF9890, alpha: (1, 0.24))
        static let neutralChip = dynamic(0x000000, 0xFFFFFF, alpha: (0.06, 0.10))
        // Chart series: categorical slots 1 and 2, checked for colour-blind separation and 3:1
        // contrast on the card surface in both modes.
        static let download = dynamic(0x2A78D6, 0x3987E5)
        static let upload = dynamic(0xEB6834, 0xD95926)
    }

    enum Radius {
        static let inner: CGFloat = 8
        static let element: CGFloat = 12     // buttons, inputs, selectors
        static let container: CGFloat = 16   // cards, panels
    }

    /// 4 px grid: space(2) = 8.
    static func space(_ n: CGFloat) -> CGFloat { n * 4 }

    enum Font {
        static let h3 = figtree(17, .semibold)
        static let large = figtree(17, .semibold)
        static let label = figtree(14, .medium)
        static let body = figtree(14, .regular)
        static let supporting = figtree(12, .regular)
        static let h6 = figtree(10, .semibold)
        static let code = SwiftUI.Font.system(size: 12, design: .monospaced)

        /// Figtree when bundled (see scripts/bundle.sh), else the system font. (A missing custom font
        /// would fall back without its weight, so check first.)
        static func figtree(_ size: CGFloat, _ weight: SwiftUI.Font.Weight) -> SwiftUI.Font {
            hasFigtree ? .custom("Figtree", size: size).weight(weight) : .system(size: size, weight: weight)
        }
        static let hasFigtree = NSFont(name: "Figtree", size: 12) != nil
    }

    private static func dynamic(_ light: UInt32, _ dark: UInt32, alpha: (CGFloat, CGFloat) = (1, 1)) -> SwiftUI.Color {
        SwiftUI.Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: isDark ? alpha.1 : alpha.0)
        })
    }
}

/// Astryx Card: surface colour, container radius, hairline border, no elevation.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(Astryx.Color.card, in: RoundedRectangle(cornerRadius: Astryx.Radius.container))
            .overlay(RoundedRectangle(cornerRadius: Astryx.Radius.container).strokeBorder(Astryx.Color.border))
    }
}

/// Astryx Badge: pill, status-muted fill, status text colour.
struct Badge: View {
    enum Tone { case success, warning, error, neutral }
    var text: String
    var tone: Tone

    var body: some View {
        let (fill, fg): (SwiftUI.Color, SwiftUI.Color) = switch tone {
        case .success: (Astryx.Color.successMuted, Astryx.Color.textSuccess)
        case .warning: (Astryx.Color.warningMuted, Astryx.Color.textWarning)
        case .error: (Astryx.Color.errorMuted, Astryx.Color.textError)
        case .neutral: (Astryx.Color.neutralChip, Astryx.Color.textSecondary)
        }
        Text(text)
            .font(Astryx.Font.supporting.weight(.medium))
            .foregroundStyle(fg)
            .padding(.horizontal, Astryx.space(2))
            .padding(.vertical, Astryx.space(0.5))
            .background(fill, in: Capsule())
    }
}

/// Astryx secondary/ghost button at --size-element-sm (28 px).
struct AstryxButtonStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Astryx.Font.label)
            .foregroundStyle(primary ? Astryx.Color.onAccent : Astryx.Color.textPrimary)
            .padding(.horizontal, Astryx.space(3))
            .frame(height: 28)
            .background(primary ? Astryx.Color.accent : (configuration.isPressed ? Astryx.Color.overlayHover : Astryx.Color.neutralChip),
                        in: RoundedRectangle(cornerRadius: Astryx.Radius.element))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}
