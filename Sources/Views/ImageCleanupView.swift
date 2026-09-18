import SwiftUI
import AppKit
import ImageIO

/// Identifiable scan target so `.sheet(item:)` can present the cleanup dialog.
struct ImageCleanupTarget: Identifiable {
    let url: URL
    var id: URL { url }
}

/// Dialog behind the "Cleanup Unused Images…" context-menu command. Scans the
/// chosen project/notebook folder for pictures that no document references and
/// offers to move them to the Trash or into an `Archive/` folder.
struct ImageCleanupView: View {
    let root: URL

    @Environment(\.dismiss) private var dismiss

    @State private var report: ImageCleanupReport?
    @State private var selected: Set<URL> = []
    @State private var isWorking = false
    @State private var summary: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 540, height: 480)
        .background(Color(NSColor.windowBackgroundColor))
        .task { await scan() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo.stack")
                .font(.title3)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Cleanup Unused Images")
                    .font(.headline)
                Text(root.lastPathComponent)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding()
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let report {
            if report.unusedImages.isEmpty {
                emptyState(report: report)
            } else {
                imageList(report: report)
            }
        } else {
            VStack(spacing: 8) {
                ProgressView()
                Text("Scanning for unused images…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func emptyState(report: ImageCleanupReport) -> some View {
        VStack(spacing: 10) {
            Image(systemName: summary == nil ? "checkmark.seal" : "externaldrive.badge.checkmark")
                .font(.system(size: 36))
                .foregroundColor(.green)
            Text(summary ?? "No Unused Images")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(summary == nil
                 ? "All \(report.imageCount) images in this folder are referenced by documents."
                 : "The sidebar will refresh when this dialog closes.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func imageList(report: ImageCleanupReport) -> some View {
        VStack(spacing: 0) {
            if let summary {
                Text(summary)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .background(Color.green.opacity(0.08))
            }

            List(report.unusedImages) { image in
                ImageCleanupRow(
                    image: image,
                    root: root,
                    isSelected: selected.contains(image.url),
                    onToggle: { toggled in
                        if toggled { selected.insert(image.url) } else { selected.remove(image.url) }
                    }
                )
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 3, leading: 10, bottom: 3, trailing: 10))
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 44)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if let report, !report.unusedImages.isEmpty {
                Button(selected.count == report.unusedImages.count ? "Deselect All" : "Select All") {
                    if selected.count == report.unusedImages.count {
                        selected.removeAll()
                    } else {
                        selected = Set(report.unusedImages.map(\.url))
                    }
                }

                Text("\(selected.count) selected · \(ByteCountFormatter.string(fromByteCount: Int64(selectedBytes), countStyle: .file))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button("Cancel") { dismiss() }

            Button("Archive") { perform(.archive) }
                .disabled(!canAct)
                .help("Move selected images into an Archive/ folder in \(root.lastPathComponent)")

            Button("Move to Trash", role: .destructive) { perform(.trash) }
                .buttonStyle(.borderedProminent)
                .disabled(!canAct)
        }
        .padding()
    }

    private var canAct: Bool {
        guard let report, !report.unusedImages.isEmpty, !isWorking else { return false }
        return !selected.isEmpty
    }

    private var selectedBytes: Int {
        guard let report else { return 0 }
        return report.unusedImages.filter { selected.contains($0.url) }.reduce(0) { $0 + $1.fileSize }
    }

    // MARK: - Actions

    private enum CleanupAction {
        case trash
        case archive
    }

    private func scan() async {
        let scanRoot = root
        let result = await Task.detached(priority: .userInitiated) {
            ImageCleanupScanner.scan(root: scanRoot)
        }.value
        report = result
        selected = Set(result.unusedImages.map(\.url))
    }

    private func perform(_ action: CleanupAction) {
        guard let report, canAct else { return }
        let targets = report.unusedImages.filter { selected.contains($0.url) }
        let scanRoot = root
        isWorking = true

        Task {
            let movedCount = await Task.detached(priority: .userInitiated) {
                switch action {
                case .trash: return ImageCleanupScanner.trash(targets)
                case .archive: return ImageCleanupScanner.archive(targets, into: scanRoot)
                }
            }.value

            let bytes = targets.reduce(0) { $0 + $1.fileSize }
            let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            let noun = targets.count == 1 ? "image" : "images"
            switch action {
            case .trash:
                summary = "Moved \(movedCount) of \(targets.count) \(noun) to the Trash (\(size))."
            case .archive:
                summary = "Moved \(movedCount) of \(targets.count) \(noun) to Archive/ (\(size))."
            }

            // Drop the handled images from the list and selection.
            let handled = Set(targets.map(\.url))
            self.report = ImageCleanupReport(
                unusedImages: report.unusedImages.filter { !handled.contains($0.url) },
                documentCount: report.documentCount,
                imageCount: report.imageCount - handled.count
            )
            selected.subtract(handled)
            isWorking = false

            // Keep the sidebar (and notebooks) in sync with the moved files.
            NotificationCenter.default.post(name: .refreshProjectSidebar, object: nil)
        }
    }
}

/// NSImage isn't Sendable; this box carries a decoded thumbnail across the
/// detached task boundary that produces it.
private struct SendableImage: @unchecked Sendable {
    let image: NSImage?
}

/// One row in the cleanup list: checkbox, thumbnail, name, path, size.
private struct ImageCleanupRow: View {
    let image: UnusedImage
    let root: URL
    let isSelected: Bool
    var onToggle: (Bool) -> Void

    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            Button(action: { onToggle(!isSelected) }) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)

            thumbnailView
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(image.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(relativePath)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(ByteCountFormatter.string(fromByteCount: Int64(image.fileSize), countStyle: .file))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { onToggle(!isSelected) }
        .help(image.url.path)
        .task(id: image.url) {
            let url = image.url
            let boxed = await Task.detached(priority: .utility) {
                SendableImage(image: Self.downsampledThumbnail(for: url))
            }.value
            thumbnail = boxed.image
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.1))
                .overlay {
                    Image(systemName: "photo")
                        .foregroundColor(.secondary)
                }
        }
    }

    private var relativePath: String {
        let rootPath = root.standardizedFileURL.path
        let imagePath = image.url.standardizedFileURL.path
        return imagePath.hasPrefix(rootPath + "/") ? "." + String(imagePath.dropFirst(rootPath.count)) : imagePath
    }

    /// Small thumbnail via ImageIO downsampling so full-size images are never
    /// decoded into memory just for the list.
    private nonisolated static func downsampledThumbnail(for url: URL, maxPixelSize: CGFloat = 88) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return NSImage(contentsOf: url) // SVG and exotic formats go through AppKit
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: 44, height: 44))
    }
}
