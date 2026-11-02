import Foundation
import Combine
import AppKit
import SwiftUI

/// Live state of a running PDF import, observed by `PDFImportProgressWindow`.
///
/// A big import takes minutes (the 1,550-page Jerome commentary takes about
/// 20), so "Importing…" in the toolbar caption was not enough to tell
/// progress from a hang. This carries a page count, the current stage and a
/// log, and its Cancel button cancels the import task.
@MainActor
final class PDFImportProgress: ObservableObject, Identifiable {
    enum Phase: Equatable {
        case preparing, reading, analysing, figures, ai, writing, finished, failed, cancelled
    }

    let id = UUID()
    let fileName: String
    let totalPages: Int

    @Published var phase: Phase = .preparing
    /// 1-based page being worked on, for the reading and analysis stages.
    @Published var page = 0
    @Published var message = "Preparing…"
    @Published var log: [String] = []
    @Published var isFinished = false
    @Published var failure: String?
    /// Set when the import wrote its files.
    @Published var outputURL: URL?

    /// Called by the Cancel button; cancels the task running the import.
    var onCancel: (() -> Void)?

    init(fileName: String, totalPages: Int) {
        self.fileName = fileName
        self.totalPages = totalPages
    }

    /// 0…1 across the whole import. Reading and analysis are weighted by
    /// page; the rest only nudges the bar.
    var fraction: Double {
        guard totalPages > 0 else { return 0 }
        let pages = Double(min(page, totalPages)) / Double(totalPages)
        switch phase {
        case .preparing: return 0
        case .reading, .analysing: return 0.05 + pages * 0.65
        case .figures: return 0.72
        case .ai: return 0.78
        case .writing: return 0.92
        case .finished, .failed, .cancelled: return 1
        }
    }

    var title: String {
        switch phase {
        case .preparing: return "Preparing import…"
        case .reading: return "Reading page \(page) of \(totalPages)"
        case .analysing: return "Analysing layout of page \(page) of \(totalPages)"
        case .figures: return "Saving figures…"
        case .ai: return "Transcribing formulas and tables with AI…"
        case .writing: return "Writing the Typst file…"
        case .finished: return "Import finished"
        case .failed: return "Import failed"
        case .cancelled: return "Import cancelled"
        }
    }

    /// A line for the log, kept short: the last few are shown.
    func append(_ text: String) {
        log.append(text)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    /// The callback the importer calls: "Reading page 3 of 1550…".
    func progressHandler() -> PDFImporter.Progress {
        { [weak self] message in
            Task { @MainActor in self?.apply(message) }
        }
    }

    /// Maps the importer's text onto the structured state, so the window can
    /// show a bar rather than a sentence.
    func apply(_ text: String) {
        message = text
        append(text)
        if let range = text.range(of: #"page (\d+)"#, options: .regularExpression) {
            let numbers = text[range].split(separator: " ").compactMap { Int($0) }
            if let first = numbers.first { page = first }
        }
        if text.hasPrefix("Reading page") { phase = .reading }
        else if text.hasPrefix("Recognising text") { phase = .reading }
        else if text.hasPrefix("Analysing layout") { phase = .analysing }
        else if text.hasPrefix("Saving figures") { phase = .figures }
        else if text.hasPrefix("AI:") || text.hasPrefix("AI unavailable") { phase = .ai }
        else if text.hasPrefix("Writing") { phase = .writing }
    }

    func finish(output: URL) {
        outputURL = output
        phase = .finished
        message = "Wrote \(output.lastPathComponent)."
        append(message)
        isFinished = true
    }

    func fail(_ reason: String) {
        failure = reason
        phase = .failed
        message = reason
        append("Failed: \(reason)")
        isFinished = true
    }

    func markCancelled() {
        phase = .cancelled
        message = "Cancelled."
        append(message)
        isFinished = true
    }
}

/// The window shown while a PDF import runs: a page counter, a progress bar,
/// a scrolling log, and Cancel. Closing it does not stop the import; only
/// Cancel (or the import finishing) does.
@MainActor
final class PDFImportProgressWindow {
    private static var current: PDFImportProgressWindow?

    private let window: NSWindow
    private let progress: PDFImportProgress
    private var cancellables: Set<AnyCancellable> = []

    /// Shows the window for `progress`, replacing any window already open.
    static func show(_ progress: PDFImportProgress) {
        current?.close()
        let window = PDFImportProgressWindow(progress: progress)
        current = window
        window.present()
    }

    private init(progress: PDFImportProgress) {
        self.progress = progress
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        self.window = window
        let content = PDFImportProgressView(
            progress: progress,
            onCancel: { [weak progress] in progress?.onCancel?() },
            onClose: { [weak window] in window?.orderOut(nil) })
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(x: 0, y: 0, width: 560, height: 380)
        window.title = "Import PDF"
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                               queue: .main) { _ in
            Task { @MainActor in if let current = Self.current, current.window === window { Self.current = nil } }
        }
    }

    private func present() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Close automatically on success after a moment; failures stay, so
        // the reason is readable.
        progress.$phase
            .sink { [weak self] phase in
                guard phase == .finished else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    guard self?.progress.phase == .finished else { return }
                    self?.close()
                }
            }
            .store(in: &cancellables)
    }

    private func close() {
        window.orderOut(nil)
        if Self.current === self { Self.current = nil }
    }
}


/// The content of `PDFImportProgressWindow`.
struct PDFImportProgressView: View {
    @ObservedObject var progress: PDFImportProgress
    var onCancel: () -> Void
    var onClose: () -> Void
    /// True from the moment Cancel is pressed: the import stops at its next
    /// check, so the button must not invite a second press meanwhile.
    @State private var isCancelling = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundColor(tint)
                Text(progress.title).font(.headline)
                Spacer()
                if progress.phase == .finished, let output = progress.outputURL {
                    Button("Open \(output.lastPathComponent)") {
                        NotificationCenter.default.post(name: .openProjectAndFile, object: output)
                        onClose()
                    }
                }
            }
            Text(progress.fileName).font(.caption).foregroundColor(.secondary)

            ProgressView(value: progress.fraction) {
                Text(progress.phase == .finished ? "Done" : "\(Int(progress.fraction * 100))%")
                    .font(.caption2)
            }

            Text(progress.message)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(progress.log.enumerated()), id: \.offset) { index, line in
                            Text(line).font(.caption.monospaced()).foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                }
                .frame(height: 180)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(6)
                .onReceive(progress.$log) { lines in
                    if !lines.isEmpty { proxy.scrollTo(lines.count - 1, anchor: .bottom) }
                }
            }

            HStack {
                if progress.isFinished {
                    Text("The Typst file is in the project.")
                        .font(.caption2).foregroundColor(.secondary)
                    Spacer()
                    Button("Close", action: onClose).keyboardShortcut(.defaultAction)
                } else if isCancelling {
                    Text("Cancelling…")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                    ProgressView().controlSize(.small)
                } else {
                    Text("You can keep working. Closing this window does not stop the import.")
                        .font(.caption2).foregroundColor(.secondary)
                    Spacer()
                    Button("Cancel Import") {
                        isCancelling = true
                        progress.message = "Cancelling after the current step…"
                        onCancel()
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 560, height: 380)
    }

    private var icon: String {
        switch progress.phase {
        case .finished: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle"
        default: return "doc.viewfinder"
        }
    }

    private var tint: Color {
        switch progress.phase {
        case .finished: return .green
        case .failed: return .orange
        case .cancelled: return .secondary
        default: return .accentColor
        }
    }
}
