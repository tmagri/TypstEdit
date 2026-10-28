import SwiftUI

/// The collapsible stash list under the change groups. Shown only when the
/// repository has stashes; collapsed by default to keep the sidebar compact.
struct GitStashesSection: View {
    let stashes: [GitStash]
    let isBusy: Bool
    let canChangeWorkingTree: Bool
    let onApply: (GitStash) -> Void
    let onPop: (GitStash) -> Void
    let onDrop: (GitStash) -> Void
    @EnvironmentObject private var themeManager: ThemeManager
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button { isExpanded.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Stashes").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(themeManager.textColor)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(isExpanded ? "Collapse" : "Expand") Stashes")
                Spacer(minLength: 0)
                Text("\(stashes.count)")
                    .font(.system(size: 10))
                    .foregroundColor(themeManager.secondaryTextColor)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            if isExpanded {
                ForEach(stashes) { stash in
                    GitStashRowView(
                        stash: stash,
                        isBusy: isBusy,
                        canChangeWorkingTree: canChangeWorkingTree,
                        onApply: { onApply(stash) },
                        onPop: { onPop(stash) },
                        onDrop: { onDrop(stash) }
                    )
                }
            }
        }
    }
}

private struct GitStashRowView: View {
    let stash: GitStash
    let isBusy: Bool
    let canChangeWorkingTree: Bool
    let onApply: () -> Void
    let onPop: () -> Void
    let onDrop: () -> Void
    @EnvironmentObject private var themeManager: ThemeManager
    @State private var hovering = false

    private var title: String {
        let message = stash.message.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? stash.id : message
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "tray.full")
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .foregroundColor(themeManager.textColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let date = stash.date {
                    Text(date, style: .relative)
                        .font(.system(size: 9))
                        .foregroundColor(themeManager.secondaryTextColor)
                }
            }
            Spacer(minLength: 0)
            Button(action: onApply) { Image(systemName: "arrow.down.circle") }
                .buttonStyle(.plain)
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
                .disabled(isBusy || !canChangeWorkingTree)
                .help(applyHelp)
                .accessibilityLabel("Apply \(stash.id)")
            Button(action: onPop) { Image(systemName: "arrow.up.circle") }
                .buttonStyle(.plain)
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
                .disabled(isBusy || !canChangeWorkingTree)
                .help(popHelp)
                .accessibilityLabel("Pop \(stash.id)")
            Button(action: onDrop) { Image(systemName: "trash") }
                .buttonStyle(.plain)
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
                .disabled(isBusy)
                .help("Drop \(stash.id)")
                .accessibilityLabel("Drop \(stash.id)")
        }
        .font(.system(size: 11))
        .padding(.leading, 12)
        .padding(.trailing, 12)
        .frame(height: 23)
        .background(hovering ? themeManager.accentColor.opacity(0.08) : Color.clear)
        .onHover { hovering = $0 }
        .help("\(stash.id) — \(title)")
        .contextMenu {
            Button("Apply Stash") { onApply() }
                .disabled(isBusy || !canChangeWorkingTree)
            Button("Pop Stash") { onPop() }
                .disabled(isBusy || !canChangeWorkingTree)
            Divider()
            Button("Drop Stash…", role: .destructive) { onDrop() }
                .disabled(isBusy)
        }
    }

    private var applyHelp: String {
        canChangeWorkingTree ? "Apply the stash and keep it in the list" : "Save the open file before you apply a stash"
    }

    private var popHelp: String {
        canChangeWorkingTree ? "Apply the stash and remove it from the list" : "Save the open file before you pop a stash"
    }
}
