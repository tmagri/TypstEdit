import Foundation
import CoreGraphics
import Vision
import AppKit

/// Screen capture + OCR via macOS's own frameworks: `screencapture` for the
/// interactive crosshair (the same tool the system screenshot shortcut uses)
/// and Vision's `VNRecognizeTextRequest` for text recognition. Everything
/// runs on this Mac; nothing is uploaded.
enum ScreenOCR {

    enum OCRError: LocalizedError {
        case cancelled
        case captureFailed(String)
        case permissionDenied
        case noTextFound
        case recognitionFailed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return "Capture cancelled."
            case .captureFailed(let message):
                return "Could not capture the screen: \(message)"
            case .permissionDenied:
                return "Screen Recording permission is required. Open System Settings → Privacy & Security → Screen Recording and enable TypstEdit, then try again."
            case .noTextFound:
                return "No readable text was found in that area."
            case .recognitionFailed(let message):
                return "Text recognition failed: \(message)"
            }
        }
    }

    /// How much of the screen to grab.
    enum CaptureMode: String, CaseIterable, Identifiable {
        /// Drag a rectangle (the native crosshair). Esc cancels.
        case region
        /// Grab the whole main display at once.
        case wholeScreen

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .region: return "Select a region"
            case .wholeScreen: return "Whole screen"
            }
        }
    }

    /// One OCR result: the recognized text plus the pixels it came from, so
    /// the chat can show a thumbnail of exactly what was read.
    struct Extract {
        let text: String
        let image: CGImage?
        let capturedAt: Date
        /// Average Vision confidence, 0…1 — shown in the card so a doubtful
        /// read is visible instead of silently trusted.
        let confidence: Float
    }

    // MARK: - Capture

    /// Runs `screencapture` and returns the image it wrote. Interactive mode
    /// (`-i`) shows the system crosshair; `-x` silences the shutter sound.
    ///
    /// TypstEdit hides for the picture: the app's own windows are hidden for
    /// the grab (they would otherwise end up in the shot and sit under the
    /// crosshair) and brought back once the pixels are in hand — or the
    /// user cancelled.
    @MainActor
    static func capture(mode: CaptureMode) async throws -> CGImage {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("typstedit-ocr-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }

        // Same restart caveat as the shortcut path: a freshly granted Screen
        // Recording permission does not take effect until the app relaunches.
        if !hasScreenRecordingPermission() {
            _ = requestScreenRecordingPermission()
            if !hasScreenRecordingPermission() {
                throw OCRError.permissionDenied
            }
        }
        let appWasActive = NSApp.isActive
        NSApp.hide(nil)
        // Give the window server a beat to finish hiding before
        // `screencapture` reads the screen — otherwise whole-screen grabs
        // can catch the windows mid-animation.
        try? await Task.sleep(nanoseconds: 250_000_000)
        defer {
            NSApp.unhide(nil)
            // Only steal focus back if the capture started from TypstEdit.
            if appWasActive {
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        switch mode {
        case .region:
            process.arguments = ["-i", "-x", url.path]
        case .wholeScreen:
            process.arguments = ["-x", "-m", url.path]
        }
        process.standardError = Pipe()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: OCRError.captureFailed(error.localizedDescription))
            }
        }

        // screencapture exits 0 for a capture and non-zero when the user
        // presses Esc — but older builds exit 0 with no file, so check both.
        guard FileManager.default.fileExists(atPath: url.path),
              let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            if process.terminationStatus != 0 {
                throw OCRError.cancelled
            }
            throw OCRError.permissionDenied
        }
        return cgImage
    }

    /// True when this process may read the screen. macOS reports "not
    /// determined" the first time it is asked, so this only speaks up once
    /// the user has actually denied it.
    static func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Asks macOS for Screen Recording access (shows the system prompt the
    /// first time). Returns whether access is granted now.
    static func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    // MARK: - OCR

    /// Recognizes text in an image, returned in reading order (top to
    /// bottom, left to right) with the lines Vision grouped kept together.
    static func recognize(_ image: CGImage, languages: [String]) throws -> (text: String, confidence: Float) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // Vision silently ignores unsupported tags; the default stays English.
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        let usable = languages.filter { supported.contains($0) }
        request.recognitionLanguages = usable.isEmpty ? ["en-US"] : usable

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw OCRError.recognitionFailed(error.localizedDescription)
        }

        let observations = request.results ?? []
        guard !observations.isEmpty else { throw OCRError.noTextFound }

        // Vision's boxes use a bottom-left origin, so a larger midY is higher
        // on the screen. Group observations that share a band into one line,
        // then order each line left-to-right.
        let ordered = observations.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
        var lines: [[VNRecognizedTextObservation]] = []
        for observation in ordered {
            if let last = lines.last?.last,
               abs(last.boundingBox.midY - observation.boundingBox.midY)
                   < max(0.008, last.boundingBox.height * 0.5) {
                lines[lines.count - 1].append(observation)
            } else {
                lines.append([observation])
            }
        }

        var confidences: [Float] = []
        let text = lines.map { line in
            line.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                .compactMap { observation -> String? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    confidences.append(candidate.confidence)
                    return candidate.string
                }
                .joined(separator: "  ")
        }
        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        .joined(separator: "\n")

        guard !text.isEmpty else { throw OCRError.noTextFound }
        let confidence = confidences.isEmpty ? 1 : confidences.reduce(0, +) / Float(confidences.count)
        return (text, confidence)
    }

    /// Capture → recognize in one step, off the main actor for the OCR half.
    @MainActor
    static func captureAndRecognize(mode: CaptureMode, languages: [String]) async throws -> Extract {
        let image = try await capture(mode: mode)
        let (text, confidence) = try await Task.detached(priority: .userInitiated) {
            try Self.recognize(image, languages: languages)
        }.value
        return Extract(text: text, image: image, capturedAt: Date(), confidence: confidence)
    }
}
