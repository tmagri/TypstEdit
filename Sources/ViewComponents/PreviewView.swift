import SwiftUI
@preconcurrency import PDFKit

/// A `PDFView` that reports the user's *own* zoom gestures separately from
/// `autoScales` re-fitting the page. A refit (window resize, split drag) must
/// keep fit mode; a pinch, double-tap, or ⌘+/− must leave it. Inferring this
/// from `PDFViewScaleChanged` alone is unreliable, because PDFKit also posts
/// that notification for refits.
final class PreviewPDFView: PDFView {
    /// Called after a user zoom gesture changed the scale. The view has
    /// already left autoScales.
    var onUserZoom: ((CGFloat) -> Void)?

    override func magnify(with event: NSEvent) {
        handleUserZoom { super.magnify(with: event) }
    }

    override func smartMagnify(with event: NSEvent) {
        handleUserZoom { super.smartMagnify(with: event) }
    }

    override func zoomIn(_ sender: Any?) {
        handleUserZoom { super.zoomIn(sender) }
    }

    override func zoomOut(_ sender: Any?) {
        handleUserZoom { super.zoomOut(sender) }
    }

    override func scrollWheel(with event: NSEvent) {
        // ⌘-scroll zooms. Handle it like the other gestures so autoScales
        // does not refit the page and silently undo it.
        guard event.modifierFlags.contains(.command) else {
            super.scrollWheel(with: event)
            return
        }
        handleUserZoom { super.scrollWheel(with: event) }
    }

    private func handleUserZoom(_ body: () -> Void) {
        // Take manual control *before* zooming: otherwise autoScales refits
        // and silently undoes the gesture on the next resize.
        autoScales = false
        body()
        onUserZoom?(scaleFactor)
    }
}

struct PreviewView: NSViewRepresentable {
    var url: URL?
    var reloadToken: UUID?
    var colorBlindnessMode: EditorController.ColorBlindnessMode = .none
    var isPreviewDarkMode: Bool = true
    /// Desired zoom factor. `0` means "fit to window" (PDFView autoScales decides).
    var zoomScale: CGFloat = 0
    /// Called whenever the user changes zoom (pinch, CMD+/−, etc.).
    /// Final values only; fit-mode refits are not reported.
    var onZoomScaleChange: ((CGFloat) -> Void)?
    /// The scale actually in use, including the one autoScales picks while
    /// fitting. Lets "zoom in" start from what is on screen during fit mode.
    var onEffectiveScaleChange: ((CGFloat) -> Void)?
    var onWordCountChange: ((Int) -> Void)?

    @EnvironmentObject var themeManager: ThemeManager

    func makeNSView(context: Context) -> PDFView {
        print("[DEBUG] PreviewView makeNSView called")
        let pdfView = PreviewPDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.backgroundColor = isPreviewDarkMode ? NSColor(calibratedWhite: 0.1, alpha: 1.0) : .white
        pdfView.wantsLayer = true

        context.coordinator.startObservingScale(pdfView)
        context.coordinator.lastIsPreviewDarkMode = isPreviewDarkMode
        (pdfView as? PreviewPDFView)?.onUserZoom = { [weak coordinator = context.coordinator] scale in
            coordinator?.reportScale(scale)
        }
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        // Keep the callback wiring fresh.
        context.coordinator.onUserZoomChange = onZoomScaleChange
        context.coordinator.onEffectiveScaleChange = onEffectiveScaleChange

        // 1. Sync Background Color with Dark/Light state first to avoid any flash.
        let targetColor = isPreviewDarkMode ? NSColor(calibratedWhite: 0.1, alpha: 1.0) : .white
        if pdfView.backgroundColor != targetColor {
            pdfView.backgroundColor = targetColor
        }

        if pdfView.appearance?.name != .darkAqua {
            pdfView.appearance = NSAppearance(named: .darkAqua)
        }

        applyFilters(to: pdfView)

        // 2. Dark/Light mode toggle — freeze the last rendered frame so the stale
        // (wrong-mode) document isn't visible while the new PDF regenerates. This
        // eliminates the white flicker. The frozen snapshot is removed by the
        // subsequent document-reload crossfade.
        if context.coordinator.lastIsPreviewDarkMode != isPreviewDarkMode {
            context.coordinator.lastIsPreviewDarkMode = isPreviewDarkMode
            if pdfView.document != nil {
                context.coordinator.installHoldingSnapshot(on: pdfView)
            }
        }

        // 3. Apply externally-requested zoom (from the toolbar controls / state).
        // `zoomScale == 0` means "fit to window" (autoScales). Only react when the
        // *requested* value changes, so pinch-zoom and autoScales refits are not
        // fought on every SwiftUI update. Done before the transition guard so a
        // click during the 200 ms crossfade is not dropped.
        if context.coordinator.lastRequestedZoom != zoomScale {
            context.coordinator.applyZoomRequest(zoomScale, to: pdfView)
        }

        guard !context.coordinator.isTransitioning else { return }

        if context.coordinator.lastUrl != url || context.coordinator.lastToken != reloadToken {
            print("[DEBUG] PreviewView: url/token changed. newURL=\(url?.lastPathComponent ?? "nil")")

            // Avoid unnecessary reloads if URL is nil and we already have nil
            if url == nil && pdfView.document == nil { return }

            guard let url = url else {
                print("[DEBUG] PreviewView: clearing document (url is nil)")
                pdfView.document = nil
                context.coordinator.lastUrl = nil
                return
            }

            // Defensive: Check if file exists, is not empty, and is readable
            let fm = FileManager.default
            guard fm.fileExists(atPath: url.path),
                  let attributes = try? fm.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? Int64, size > 0,
                  fm.isReadableFile(atPath: url.path) else {
                print("[DEBUG] PreviewView: file not ready for PDFDocument (exists=\(fm.fileExists(atPath: url.path)), size=\((try? fm.attributesOfItem(atPath: url.path)[.size]) ?? "nil"), readable=\(fm.isReadableFile(atPath: url.path)))")
                // Don't clear document yet, maybe it's just a transient state during typst re-writing
                return
            }

            print("[DEBUG] PreviewView: attempting to load PDFDocument for \(url.lastPathComponent)")
            if let document = PDFDocument(url: url), document.pageCount > 0 {
                // --- Capture current view state BEFORE swapping ---
                let savedScale = pdfView.scaleFactor
                let wasFitting = context.coordinator.lastRequestedZoom <= 0
                let savedPoint = pdfView.currentDestination?.point ?? .zero
                let savedPageIndex = pdfView.currentPage.map { pdfView.document?.index(for: $0) ?? 0 } ?? 0

                // --- OVERLAP TRANSITION LOGIC ---
                if let oldDocument = pdfView.document, oldDocument.pageCount > 0 {
                    context.coordinator.isTransitioning = true
                    let snapshotView = context.coordinator.makeSnapshotView(on: pdfView)

                    pdfView.document = document

                    // Restore zoom + position, or refit when the user is in fit mode.
                    if wasFitting {
                        context.coordinator.restoreViewState(scale: nil,
                                                            pageIndex: savedPageIndex,
                                                            point: savedPoint,
                                                            on: pdfView)
                    } else {
                        context.coordinator.restoreViewState(scale: savedScale,
                                                            pageIndex: savedPageIndex,
                                                            point: savedPoint,
                                                            on: pdfView)
                    }

                    if let snap = snapshotView {
                        pdfView.addSubview(snap)
                        NSAnimationContext.runAnimationGroup { ctx in
                            ctx.duration = 0.2
                            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                            snap.animator().alphaValue = 0.0
                        } completionHandler: {
                            DispatchQueue.main.async {
                                snap.removeFromSuperview()
                                context.coordinator.clearOverlaySnapshot()
                                context.coordinator.isTransitioning = false
                            }
                        }
                    } else {
                        context.coordinator.isTransitioning = false
                    }
                } else {
                    pdfView.document = document
                    // First load: apply fit or the requested zoom, then report it.
                    if context.coordinator.lastRequestedZoom <= 0 {
                        context.coordinator.enterFitMode(on: pdfView)
                    } else {
                        context.coordinator.applyExternalZoom(context.coordinator.lastRequestedZoom, to: pdfView)
                    }
                }

                context.coordinator.lastUrl = url
                context.coordinator.lastToken = reloadToken

                // Text extraction walks every page, so it runs off the main thread on a separate
                // copy of the document. The displayed `PDFDocument` is not shared across threads.
                DispatchQueue.global(qos: .utility).async {
                    // The file can be mid-rewrite by the next compile; keep the old count then.
                    guard let copy = PDFDocument(url: url) else { return }
                    let text = copy.string ?? ""
                    let words = text.split { $0.isWhitespace || $0.isNewline }
                    let count = words.count

                    DispatchQueue.main.async {
                        // Check if document is still relevant
                        if context.coordinator.lastUrl == url {
                            self.onWordCountChange?(count)
                        }
                    }
                }
            } else {
                pdfView.document = nil
                context.coordinator.lastUrl = url
            }
        }
    }

    private func applyFilters(to view: PDFView) {
        guard let layer = view.layer else { return }

        var filters: [CIFilter] = []

        // Dark Mode / Night Mode: We now use a Typst preamble for "True Dark Mode"
        // which renders text and page colors correctly without inverting images.

        // Color Blindness
        if colorBlindnessMode != .none {
            let matrix: [CGFloat]
            switch colorBlindnessMode {
            case .protanopia:
                matrix = [0.567, 0.433, 0.0, 0.0, 0.558, 0.442, 0.0, 0.0, 0.0, 0.242, 0.758, 0.0, 0.0, 0.0, 0.0, 1.0]
            case .deuteranopia:
                matrix = [0.625, 0.375, 0.0, 0.0, 0.7, 0.3, 0.0, 0.0, 0.0, 0.3, 0.7, 0.0, 0.0, 0.0, 0.0, 1.0]
            case .tritanopia:
                matrix = [0.95, 0.05, 0.0, 0.0, 0.0, 0.433, 0.567, 0.0, 0.0, 0.475, 0.525, 0.0, 0.0, 0.0, 0.0, 1.0]
            case .none:
                matrix = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1]
            }

            if let colorMatrix = CIFilter(name: "CIColorMatrix") {
                colorMatrix.setValue(CIVector(values: [matrix[0], matrix[1], matrix[2], matrix[3]], count: 4), forKey: "inputRVector")
                colorMatrix.setValue(CIVector(values: [matrix[4], matrix[5], matrix[6], matrix[7]], count: 4), forKey: "inputGVector")
                colorMatrix.setValue(CIVector(values: [matrix[8], matrix[9], matrix[10], matrix[11]], count: 4), forKey: "inputBVector")
                colorMatrix.setValue(CIVector(values: [matrix[12], matrix[13], matrix[14], matrix[15]], count: 4), forKey: "inputAVector")
                filters.append(colorMatrix)
            }
        }

        layer.filters = filters
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator {
        var lastUrl: URL?
        var lastToken: UUID?
        var isTransitioning: Bool = false
        var lastIsPreviewDarkMode: Bool = true

        /// The most recent user scale factor, used to dedupe notifications.
        var lastReportedScale: CGFloat = 0
        /// The last effective (on-screen) scale, including autoScales fits.
        var lastEffectiveScale: CGFloat = 0
        /// The last zoom value SwiftUI asked for. `0` means fit mode.
        var lastRequestedZoom: CGFloat = 0
        /// True while we are programmatically setting scaleFactor (suppresses echo).
        var isApplyingExternalZoom: Bool = false

        /// Tracks the currently-overlayed snapshot so only one is ever live.
        private weak var overlaySnapshot: NSImageView?

        var onUserZoomChange: ((CGFloat) -> Void)?
        var onEffectiveScaleChange: ((CGFloat) -> Void)?

        nonisolated(unsafe) private var scaleObserver: NSObjectProtocol?
        private weak var observedPdfView: PDFView?

        // MARK: - Scale observation
        func startObservingScale(_ pdfView: PDFView) {
            observedPdfView = pdfView
            scaleObserver = NotificationCenter.default.addObserver(
                forName: .PDFViewScaleChanged,
                object: pdfView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self = self else { return }
                    self.handleScaleChanged(in: pdfView)
                }
            }
        }

        private func handleScaleChanged(in pdfView: PDFView) {
            guard !isApplyingExternalZoom else { return }
            reportEffectiveScale(pdfView.scaleFactor)

            // While autoScales owns the scale, every change is a refit caused
            // by a resize (window, split drag) and fit mode must survive it.
            // User zooms turn autoScales off first (see PreviewPDFView), so
            // only those reach the report below.
            guard !pdfView.autoScales else { return }
            reportScale(pdfView.scaleFactor)
        }

        /// Tells SwiftUI which scale is really on screen. Used by the zoom
        /// buttons so "zoom in" from fit mode continues from the fitted size.
        func reportEffectiveScale(_ scale: CGFloat) {
            guard abs(scale - lastEffectiveScale) > 0.001 else { return }
            lastEffectiveScale = scale
            onEffectiveScaleChange?(scale)
        }

        func reportScale(_ scale: CGFloat) {
            guard !isApplyingExternalZoom else { return }
            guard abs(scale - lastReportedScale) > 0.001 else { return }
            lastReportedScale = scale
            lastEffectiveScale = scale
            onEffectiveScaleChange?(scale)
            onUserZoomChange?(scale)
        }

        /// Applies a SwiftUI-requested zoom. `0` re-enters fit mode.
        func applyZoomRequest(_ zoom: CGFloat, to pdfView: PDFView) {
            lastRequestedZoom = zoom
            if zoom <= 0 {
                if !pdfView.autoScales {
                    enterFitMode(on: pdfView)
                }
                return
            }
            // The request may just be the echo of a scale we reported after a
            // pinch. Writing it back would fight the live gesture, so ignore
            // values that already match what is on screen.
            if abs(pdfView.scaleFactor - zoom) < 0.005 {
                lastReportedScale = zoom
                lastEffectiveScale = zoom
                return
            }
            applyExternalZoom(zoom, to: pdfView)
        }

        /// Turns autoScales back on and reports the resulting fitted scale.
        func enterFitMode(on pdfView: PDFView) {
            isApplyingExternalZoom = true
            pdfView.autoScales = true
            // `scaleFactorForSizeToFit` is correct immediately; the actual
            // scaleFactor can lag until the next layout pass.
            let fitted = pdfView.scaleFactorForSizeToFit
            lastReportedScale = fitted
            lastEffectiveScale = fitted
            onEffectiveScaleChange?(fitted)
            DispatchQueue.main.async { [weak self, weak pdfView] in
                guard let self else { return }
                if let pdfView {
                    let settled = pdfView.scaleFactor
                    self.lastEffectiveScale = settled
                    self.onEffectiveScaleChange?(settled)
                }
                self.isApplyingExternalZoom = false
            }
        }

        func applyExternalZoom(_ scale: CGFloat, to pdfView: PDFView) {
            isApplyingExternalZoom = true
            // Setting scaleFactor alone leaves autoScales on, which would
            // refit (and undo the zoom) on the next resize.
            pdfView.autoScales = false
            pdfView.scaleFactor = scale
            lastReportedScale = scale
            lastEffectiveScale = scale
            DispatchQueue.main.async { [weak self] in
                self?.isApplyingExternalZoom = false
            }
        }

        /// Restore zoom + scroll position after a document swap. A `nil` scale
        /// means the view is in fit mode, so autoScales keeps handling it.
        func restoreViewState(scale: CGFloat?, pageIndex: Int, point: NSPoint, on pdfView: PDFView) {
            isApplyingExternalZoom = true
            if let scale {
                pdfView.autoScales = false
                pdfView.scaleFactor = scale
                lastReportedScale = scale
                lastEffectiveScale = scale
            } else {
                pdfView.autoScales = true
                let fitted = pdfView.scaleFactorForSizeToFit
                lastReportedScale = fitted
                lastEffectiveScale = fitted
            }
            if let doc = pdfView.document, let page = doc.page(at: max(0, min(pageIndex, doc.pageCount - 1))) {
                pdfView.go(to: PDFDestination(page: page, at: point))
            }
            DispatchQueue.main.async { [weak self] in
                self?.isApplyingExternalZoom = false
            }
        }

        // MARK: - Snapshot helpers
        /// Captures the current rendering of the PDFView as an image and returns an
        /// image view containing it (for use as a frozen overlay during transitions).
        func makeSnapshotView(on pdfView: PDFView) -> NSImageView? {
            let snapshotView = NSImageView(frame: pdfView.bounds)
            snapshotView.imageScaling = .scaleProportionallyUpOrDown
            snapshotView.wantsLayer = true
            snapshotView.layer?.opacity = 1.0

            if let bitmap = pdfView.bitmapImageRepForCachingDisplay(in: pdfView.bounds) {
                pdfView.cacheDisplay(in: pdfView.bounds, to: bitmap)
                let image = NSImage(size: pdfView.bounds.size)
                image.addRepresentation(bitmap)
                snapshotView.image = image
            }
            return snapshotView
        }

        /// Freezes the current frame on top of the PDFView so subsequent background /
        /// document changes don't show through until the new document crossfades in.
        /// Used on dark/light mode toggle to prevent the white flicker.
        func installHoldingSnapshot(on pdfView: PDFView) {
            clearOverlaySnapshot()
            guard let snap = makeSnapshotView(on: pdfView) else { return }
            pdfView.addSubview(snap)
            overlaySnapshot = snap
        }

        func clearOverlaySnapshot() {
            overlaySnapshot?.removeFromSuperview()
            overlaySnapshot = nil
        }

        deinit {
            if let obs = scaleObserver {
                NotificationCenter.default.removeObserver(obs)
            }
        }
    }
}
