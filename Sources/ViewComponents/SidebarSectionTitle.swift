import SwiftUI

/// The small-caps section title used in the sidebar headers ("PROJECT",
/// "NOTEBOOKS"). As the sidebar is squeezed narrower, this text used to wrap
/// into a second line ("NOTEBO / OKS"), which looked broken and grew the
/// header. Instead, the title now disappears once it no longer fits — the
/// header keeps its single-line height, the icon buttons keep their room, and
/// the full text stays available through the tooltip and accessibility label.
struct SidebarSectionTitle: View {
    /// The full title. Also used as the tooltip/accessibility text even when
    /// the visible label has collapsed away.
    let text: String
    /// Optional abbreviated variant (e.g. "LONGPROJECT…") tried before the
    /// title hides entirely. Long project-folder names use this so a hint of
    /// the name survives as long as possible.
    var fallbackText: String? = nil

    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        ViewThatFits(in: .horizontal) {
            label(text)
            if let fallbackText {
                label(fallbackText)
            }
            Color.clear
                .frame(width: 0, height: 0)
        }
        .help(text)
        .accessibilityLabel(Text(text))
    }

    /// The title at one consistent style, pinned to its ideal width so the
    /// layout engine never squeezes (and thereby wraps) the text itself.
    private func label(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .bold))
            .tracking(1)
            .foregroundColor(themeManager.textColor.opacity(0.6))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}
