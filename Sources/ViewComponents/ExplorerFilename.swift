import SwiftUI
import AppKit

/// A filename in a sidebar row, sized to the width the row actually gives it.
///
/// Rows used to cut every name at a fixed 12 characters, so a wide panel
/// truncated exactly like a narrow one and left empty space on its right. Now
/// the full name is shown whenever it fits, and only then is it shortened —
/// head, ellipsis, extension ("DropFlyTime….tif") — keeping the extension
/// visible so eight similar files stay distinguishable. The full name is still
/// available through the row's tooltip.
struct ExplorerFilename: View {
    /// The complete file or folder name, extension included.
    let name: String
    /// Extension to keep visible when the name is shortened, without the dot.
    /// Empty for folders and for names with no extension.
    var pathExtension: String = ""
    /// Marker appended after the extension and never truncated (e.g. "*" for
    /// unsaved changes), so it can't be lost to the ellipsis.
    var trailingMark: String = ""
    /// Row font size; used to draw the name and to measure it against the
    /// available width.
    var fontSize: CGFloat = 12
    /// Row font weight, matched exactly by the measurement.
    var fontWeight: Font.Weight = .regular

    /// Width of the row's filename area, measured once per layout change.
    @State private var availableWidth: CGFloat = 0

    var body: some View {
        Text(displayName)
            .font(.system(size: fontSize, weight: fontWeight))
            .lineLimit(1)
            // Safety net: if the measured width is slightly off (or the row is
            // narrower than the measurement), middle truncation still keeps
            // both the head and the extension on screen.
            .truncationMode(.middle)
            // Take the row's leftover width so the name can grow with the
            // panel instead of sitting at a fixed character count. Rows that
            // still need a trailing control keep their room, because that
            // control is not flexible.
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GeometryReader { proxy in
                Color.clear
                    .onAppear { availableWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { width in
                        availableWidth = width
                    }
            })
    }

    private var displayName: String {
        Self.displayName(
            for: name,
            pathExtension: pathExtension,
            trailingMark: trailingMark,
            availableWidth: availableWidth,
            fontSize: fontSize,
            fontWeight: fontWeight
        )
    }

    /// The longest form of `name` that fits `availableWidth`.
    ///
    /// Returns the full name when it fits (or when the width has not been
    /// measured yet, leaving truncation to SwiftUI), otherwise the longest
    /// head plus "…", the extension and the trailing marker.
    static func displayName(
        for name: String,
        pathExtension: String,
        trailingMark: String = "",
        availableWidth: CGFloat,
        fontSize: CGFloat,
        fontWeight: Font.Weight = .regular
    ) -> String {
        let full = name + trailingMark
        guard availableWidth > 0 else { return full }
        guard width(of: full, fontSize: fontSize, fontWeight: fontWeight) > availableWidth else {
            return full
        }

        let suffix = !pathExtension.isEmpty && name.hasSuffix("." + pathExtension)
            ? "." + pathExtension
            : ""
        let stem = String(name.dropLast(suffix.count))

        // Binary search for the longest head that still fits with the ellipsis
        // and the extension, so a wide panel shows as much of the name as it
        // can and a narrow one gives way gradually.
        var low = 0
        var high = stem.count
        var best: Int?
        while low <= high {
            let mid = (low + high) / 2
            let candidate = shortened(stem: stem, head: mid, suffix: suffix, mark: trailingMark)
            if width(of: candidate, fontSize: fontSize, fontWeight: fontWeight) <= availableWidth {
                best = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        if let best {
            return shortened(stem: stem, head: best, suffix: suffix, mark: trailingMark)
        }
        // Not even the ellipsis plus the extension fits: keep the extension and
        // let SwiftUI truncate the rest. The marker survives at the tail.
        return "…" + suffix + trailingMark
    }

    private static func shortened(stem: String, head: Int, suffix: String, mark: String) -> String {
        String(stem.prefix(head)) + "…" + suffix + mark
    }

    private static func width(of text: String, fontSize: CGFloat, fontWeight: Font.Weight) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize, weight: nsWeight(fontWeight))
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// `Font.Weight` and `NSFont.Weight` share the same slider values but not a
    /// common protocol, so the handful of weights the sidebar uses map across.
    private static func nsWeight(_ weight: Font.Weight) -> NSFont.Weight {
        switch weight {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }
}
