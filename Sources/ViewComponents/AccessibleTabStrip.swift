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

/// What the strip needs to know before it can decide whether its text labels
/// still fit: how much width it was handed, and how wide its widest label is.
private struct TabStripFit: Equatable {
    var availableWidth: CGFloat = 0
    var widestLabelWidth: CGFloat = 0
}

private struct TabStripFitKey: PreferenceKey {
    static var defaultValue: TabStripFit { TabStripFit() }

    static func reduce(value: inout TabStripFit, nextValue: () -> TabStripFit) {
        let next = nextValue()
        value.availableWidth = max(value.availableWidth, next.availableWidth)
        value.widestLabelWidth = max(value.widestLabelWidth, next.widestLabelWidth)
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
///
/// Tabs are equal-width, so in a narrow sidebar the labels used to wrap or
/// squeeze into fragments ("Fil / es", "Notebo / oks"). The strip now
/// measures how wide its widest label actually is and, once that no longer
/// fits, drops the text and keeps only the icons (with a tooltip and the
/// accessibility label still carrying the name). Resizing back out restores
/// the labels.
struct AccessibleTabStrip<Value: Hashable>: View {
    let tabs: [AccessibleTab<Value>]
    @Binding var selection: Value
    @EnvironmentObject var themeManager: ThemeManager

    @State private var fit = TabStripFit()

    private let tabSpacing: CGFloat = 2

    /// Every tab is an equal share of the strip, so all of them must be able
    /// to hold the widest label in the strip.
    private var showsLabels: Bool {
        guard fit.availableWidth > 0, fit.widestLabelWidth > 0 else { return true }
        let needed = fit.widestLabelWidth * CGFloat(tabs.count)
            + tabSpacing * CGFloat(max(tabs.count - 1, 0))
        return needed <= fit.availableWidth + 0.5
    }

    var body: some View {
        HStack(spacing: tabSpacing) {
            ForEach(tabs) { tab in
                tabButton(for: tab)
            }
        }
        .background { availableWidthReader }
        .background(alignment: .topLeading) { labelWidthProbe }
        .onPreferenceChange(TabStripFitKey.self) { fit = $0 }
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
                tabLabel(for: tab, isSelected: isSelected, showsTitle: showsLabels)
                    .foregroundColor(isSelected ? tab.color : themeManager.textColor.opacity(0.55))
                    .frame(maxWidth: .infinity)
                    // A fixed row height keeps the strip from jumping when
                    // the labels disappear: icon-only and labelled tabs are
                    // the same height.
                    .frame(height: 20)
                    .padding(.vertical, 4)
                    .background(isSelected ? tab.color.opacity(0.14) : Color.clear)

                // The "rectangle underneath" — a solid, colour-coded tab
                // indicator rather than a pill, so each panel reads as an
                // actual tab instead of a toggle button.
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(isSelected ? tab.color : Color.clear)
                    .frame(maxWidth: .infinity)
                    .frame(height: 3)
            }
            // Giving the *label* itself an explicit, fully-expanded content
            // shape — rather than tacking .contentShape onto the Button
            // from the outside — is what actually gets AppKit to treat the
            // whole painted row as the hit target on macOS. Without this,
            // the Button's real click region can stay sized to the label's
            // intrinsic (unexpanded) content and just sit centered inside
            // the wider frame we draw, which is what made these tabs feel
            // "sticky": only a click near dead-center registered, and
            // anything nearer the edges needed a second try.
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tab.title)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])
        .accessibilityLabel(Text(tab.title))
    }

    /// The icon plus, when there is room for it, the title.
    private func tabLabel(for tab: AccessibleTab<Value>, isSelected: Bool, showsTitle: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: isSelected ? (tab.selectedSystemImage ?? tab.systemImage) : tab.systemImage)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            if showsTitle {
                Text(tab.title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                    // Truncate rather than wrap if the measurement below is
                    // ever off by a fraction of a point.
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 4)
    }

    private var availableWidthReader: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: TabStripFitKey.self,
                value: TabStripFit(availableWidth: proxy.size.width)
            )
        }
    }

    /// Hidden, fixed-size copies of every label. They don't take part in the
    /// visible layout; they only report the widest label width. The selected
    /// style is measured because bold text and filled icons are the widest
    /// case a tab has to accommodate.
    private var labelWidthProbe: some View {
        ZStack(alignment: .topLeading) {
            ForEach(tabs) { tab in
                tabLabel(for: tab, isSelected: true, showsTitle: true)
                    .fixedSize()
                    .hidden()
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: TabStripFitKey.self,
                                value: TabStripFit(widestLabelWidth: proxy.size.width)
                            )
                        }
                    }
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
