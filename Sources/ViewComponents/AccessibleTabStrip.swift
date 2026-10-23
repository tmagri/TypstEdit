import SwiftUI

/// One entry in an `AccessibleTabStrip`: a label, SF Symbol, and a distinct
/// accent color.
///
/// Color is only one of three signals used to mark the active tab (the
/// others being bold text and a filled vs. outline icon), so the strip stays
/// legible for colorblind users and still reads correctly in grayscale.
struct AccessibleTab<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    /// Outline-style icon shown while this tab is inactive.
    let systemImage: String
    /// Filled-style icon shown while this tab is active. Defaults to
    /// `systemImage` when the symbol has no filled variant.
    var selectedSystemImage: String?
    /// The tab's accent color, used for the underline indicator, the icon,
    /// and a faint selected-state background tint.
    let color: Color

    var id: Value { value }

    init(_ value: Value, title: String, systemImage: String, selectedSystemImage: String? = nil, color: Color) {
        self.value = value
        self.title = title
        self.systemImage = systemImage
        self.selectedSystemImage = selectedSystemImage
        self.color = color
    }
}

/// A browser-style tab strip that replaces the stock macOS segmented control
/// wherever we want tabs to look and behave like *tabs*: a colored rectangle
/// sits under whichever one is active, its icon switches to a filled
/// variant, and its label turns bold.
///
/// Each tab gets its own accent color (see call sites for the specific
/// palette) chosen to stay distinguishable under the common forms of color
/// blindness and to hold WCAG-friendly contrast against the dark sidebar
/// background — color is a bonus cue here, never the only one.
struct AccessibleTabStrip<Value: Hashable>: View {
    let tabs: [AccessibleTab<Value>]
    @Binding var selection: Value
    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                tabButton(for: tab)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(themeManager.textColor.opacity(0.12))
                .frame(height: 1)
        }
    }

    private func tabButton(for tab: AccessibleTab<Value>) -> some View {
        let isSelected = tab.value == selection
        return Button {
            guard !isSelected else { return }
            withAnimation(.easeOut(duration: 0.16)) { selection = tab.value }
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: isSelected ? (tab.selectedSystemImage ?? tab.systemImage) : tab.systemImage)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    Text(tab.title)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                }
                .foregroundColor(isSelected ? tab.color : themeManager.textColor.opacity(0.55))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(isSelected ? tab.color.opacity(0.14) : Color.clear)

                // The "rectangle underneath" — a solid, colour-coded tab
                // indicator rather than a pill, so each panel reads as an
                // actual tab instead of a toggle button.
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(isSelected ? tab.color : Color.clear)
                    .frame(height: 3)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])
        .accessibilityLabel(Text(tab.title))
    }
}
