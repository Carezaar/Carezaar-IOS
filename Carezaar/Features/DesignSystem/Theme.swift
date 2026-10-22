import SwiftUI

/// Tokens measured from the v2 Figma source (see `DESIGN-SYSTEM.md`). These are the
/// shared current-design values; individual scenes keep their own measured values.
enum Theme {
    enum Palette {
        /// The one brand blue, as on Android: buttons, selected chips, the user's own chat bubble,
        /// the send and floating add buttons, links, outlines and icons (client, 22 Oct 2026).
        /// White on it, and it on white, is 4.03:1: below WCAG AA's 4.5:1 for normal-size text such
        /// as the 14–16 pt button labels and links (AA large text, 3:1, starts at 18.66 px bold).
        /// Kept at the client's request for one blue; #0071EC (4.59:1) was the AA alternative.
        static let primary = Color(hex: 0x007AFE)
        /// Links and outline-button labels: the brand blue (see `primary`).
        static let primaryText = primary
        /// Fills behind white text and icons: the brand blue (see `primary`).
        static let primaryFill = primary
        static let textPrimary = Color.black
        // Stronger small-text contrast: #595959 is 7.0:1 on white and
        // 6.3:1 or better on both role panels, including thin custom-font glyphs.
        static let textSecondary = Color(hex: 0x595959)
        /// Opaque inactive controls keep their labels readable without fading
        /// the whole view. This pair has calculated sRGB contrast 5.65:1.
        static let disabledForeground = Color(hex: 0x595959)
        static let disabledBackground = Color(hex: 0xE3E7EE)
        static let surface = Color.white
        /// Client/care panels.
        static let clientPanel = Color(hex: 0xEDF4FC)
        /// Caregiver panels.
        static let caregiverPanel = Color(hex: 0xEFF9F7)
        static let success = Color(hex: 0x01BB8A)
        /// Satisfied password-rule text: 4.874:1 on the #E9F8F3 rule-card fill.
        /// Keep the brighter success token for its existing icon treatments.
        static let successText = Color(hex: 0x047A5A)
        // Pure red is 4.0:1 on white; #E00000 is 5.0:1, for error text people must read.
        static let error = Color(hex: 0xE00000)
        static let privacy = Color(hex: 0x9247F5)
        static let separator = Color(hex: 0xE5E5E5)
        static let background = Color(hex: 0xFAFAFA)

        /// Panel tint for a role, matching the source's two panel colours.
        static func panel(for role: UserRole) -> Color {
            role == .client ? clientPanel : caregiverPanel
        }
    }

    enum Spacing {
        static let xs: CGFloat = 8
        static let s: CGFloat = 16
        static let m: CGFloat = 20
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
    }

    enum Radius {
        static let field: CGFloat = 12
        static let card: CGFloat = 16
        static let sheet: CGFloat = 24
    }

    /// Vazirmatn is bundled and registered at launch; `custom` falls back to the
    /// system face automatically if registration failed.
    enum Typography {
        static func heading(_ size: CGFloat = 28) -> Font { font(size, weight: .bold, relativeTo: .largeTitle) }
        static func title(_ size: CGFloat = 20) -> Font { font(size, weight: .semibold, relativeTo: .title2) }
        static func control(_ size: CGFloat = 16) -> Font { font(size, weight: .medium, relativeTo: .body) }
        /// Labels on brand-blue fills: bold, at least 14 pt (white on #007AFE is 4.03:1; see `primary`).
        static func filledLabel(_ size: CGFloat = 16) -> Font { font(max(size, 14), weight: .bold, relativeTo: .body) }
        static func body(_ size: CGFloat = 14) -> Font { font(size, weight: .regular, relativeTo: .body) }
        static func caption(_ size: CGFloat = 12) -> Font { font(max(size, 12), weight: .regular, relativeTo: .caption) }

        private static func font(_ size: CGFloat, weight: Font.Weight, relativeTo style: Font.TextStyle) -> Font {
            .custom("Vazirmatn", size: size, relativeTo: style).weight(weight)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}
