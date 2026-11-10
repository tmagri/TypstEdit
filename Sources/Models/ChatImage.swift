import AppKit
import ImageIO
import UniformTypeIdentifiers

/// One image the user attached to an AI Chat message.
///
/// Some models can read images as reference material (a screenshot of a table,
/// a scanned page, a sketch of a layout). The bytes travel to the provider as
/// base64 with the message they were attached to, and live on the transcript so
/// the panel can show them again after a restart.
///
/// Persisted with the conversation (see `ChatMessage.images`), and downsized on
/// the way in (see `ChatImageLoader`) so a 12-megapixel photo can't grow a
/// session file by tens of megabytes or blow past a provider's per-image limit.
struct ChatImage: Codable, Identifiable, Equatable, Sendable {
    /// Stable identity for SwiftUI rows and for cheap equality: transcripts
    /// are compared on every streamed token, and comparing megabytes of base64
    /// there would make the panel crawl.
    let id: UUID
    /// `image/png`, `image/jpeg`, … — what the provider needs to decode it.
    let mediaType: String
    /// Base64 of the (already downsized) image bytes.
    let base64: String
    /// Pixel size of the stored image, used for the token estimate and the
    /// thumbnail's aspect ratio.
    let width: Int
    let height: Int
    /// Original file name, shown in the attachment's tooltip.
    var fileName: String?

    init(
        id: UUID = UUID(),
        mediaType: String,
        base64: String,
        width: Int,
        height: Int,
        fileName: String? = nil
    ) {
        self.id = id
        self.mediaType = mediaType
        self.base64 = base64
        self.width = width
        self.height = height
        self.fileName = fileName
    }

    /// Only the identity, deliberately: see `id`. Two decodes of the same saved
    /// message are equal, and a re-render never diffs the pixels.
    static func == (lhs: ChatImage, rhs: ChatImage) -> Bool {
        lhs.id == rhs.id
    }

    /// Lenient decoding, like the rest of a saved transcript: a field written
    /// by a future build (or cut short by a crash) must not make the whole
    /// conversation unreadable.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        mediaType = (try? c.decode(String.self, forKey: .mediaType)) ?? "image/png"
        base64 = (try? c.decode(String.self, forKey: .base64)) ?? ""
        width = (try? c.decode(Int.self, forKey: .width)) ?? 0
        height = (try? c.decode(Int.self, forKey: .height)) ?? 0
        fileName = try? c.decode(String.self, forKey: .fileName)
    }

    /// Bytes of the decoded image, from the base64 length (no decode needed).
    /// Kept for callers that want to report size; the budget math below uses
    /// the token estimate instead, since a provider bills pixels, not bytes.
    var byteCount: Int { base64.utf8.count * 3 / 4 }

    /// The `data:` URL OpenAI-compatible providers expect.
    var dataURL: String { "data:\(mediaType);base64,\(base64)" }
    /// Rough token cost, so the context estimate and the compaction trigger
    /// account for images instead of pretending the message is only its text.
    /// Roughly OpenAI's `(width × height) / 750`, clamped to the range a
    /// provider actually bills for one image.
    var approximateTokens: Int {
        guard width > 0, height > 0 else { return 1_024 }
        let estimate = (width * height) / 750
        return min(1_600, max(85, estimate))
    }

    /// The character cost this attachment adds to the byte-based budget math
    /// (4 characters ≈ 1 token here, the same rule the text estimates use).
    var budgetChars: Int { approximateTokens * 4 }
}
enum ChatImageError: LocalizedError {
    case unsupportedFormat
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "That file isn't an image this app can read."
        case .tooLarge:
            return "That image is too large to attach, even after shrinking it."
        }
    }
}

/// Turns picked files into attachable `ChatImage`s: downsize, re-encode, and
/// bound what one message may carry.
enum ChatImageLoader {
    /// Most images one message may carry. Providers differ (Anthropic allows
    /// many, most OpenAI-compatible servers are happier with a handful), and a
    /// long strip would crowd the composer.
    static let maxPerMessage = 6
    /// Longest edge kept, in pixels. Anthropic itself resizes to 1568, and the
    /// extra detail past that is billed without being visible to the model.
    static let maxLongEdge = 1_568
    /// Per-image ceiling on the encoded bytes (~1 MB of base64 is ~750 KB of
    /// pixels). A PNG screenshot can still carry small text at that size.
    static let maxEncodedBytes = 1_500_000
    /// Total encoded bytes one message may carry, so six images can't turn a
    /// session file into a download.
    static let maxTotalEncodedBytes = 6_000_000

    /// Formats the file picker offers and drag-and-drop accepts. All of them
    /// are re-encoded to PNG or JPEG before they reach a provider, so a HEIC
    /// photo works even though most providers can't read HEIC.
    static let supportedTypes: [UTType] = [.png, .jpeg, .gif, .webP, .heic, .heif, .tiff, .bmp]

    /// What `fit` did with the images it was given, for a short inline notice.
    struct FitResult: Equatable {
        var accepted: [ChatImage] = []
        /// Images left out because the message already had the maximum.
        var droppedForCount: Int = 0
        /// Images left out because they would exceed the size budget.
        var droppedForSize: Int = 0

        var droppedCount: Int { droppedForCount + droppedForSize }
    }

    // MARK: - Loading

    /// Reads and downsizes an image file.
    static func load(from url: URL) throws -> ChatImage {
        let data = try Data(contentsOf: url)
        return try make(from: data, fileName: url.lastPathComponent)
    }

    /// Decodes raw image bytes (a picked file, a pasted screenshot, a dropped
    /// file) into a `ChatImage`, shrinking it to a size providers accept.
    static func make(from data: Data, fileName: String? = nil) throws -> ChatImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ChatImageError.unsupportedFormat
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxLongEdge,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ChatImageError.unsupportedFormat
        }

        // Keep PNG for formats that are usually line art or screenshots (where
        // JPEG artifacts make small text unreadable), JPEG for photographs.
        let sourceType = (CGImageSourceGetType(source) as String?).flatMap(UTType.init)
        let prefersPNG = sourceType == .png || sourceType == .gif

        var encoded = prefersPNG
            ? encode(image, as: .png)
            : encode(image, as: .jpeg, quality: 0.85)
        var mediaType = prefersPNG ? UTType.png : UTType.jpeg

        // A lossless PNG of a photograph can be several megabytes; fall back to
        // JPEG rather than refusing the attachment.
        if encoded == nil || encoded!.count > maxEncodedBytes {
            if let jpeg = encode(image, as: .jpeg, quality: 0.8), jpeg.count <= maxEncodedBytes {
                encoded = jpeg
                mediaType = .jpeg
            } else if let jpeg = encode(image, as: .jpeg, quality: 0.55), jpeg.count <= maxEncodedBytes {
                encoded = jpeg
                mediaType = .jpeg
            }
        }
        guard let data = encoded, data.count <= maxEncodedBytes else {
            throw ChatImageError.tooLarge
        }

        return ChatImage(
            mediaType: mediaType.preferredMIMEType ?? "image/png",
            base64: data.base64EncodedString(),
            width: image.width,
            height: image.height,
            fileName: fileName
        )
    }

    private static func encode(_ image: CGImage, as type: UTType, quality: CGFloat? = nil) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, type.identifier as CFString, 1, nil
        ) else { return nil }
        var properties: [CFString: Any] = [:]
        if let quality {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    // MARK: - Limits

    /// Keeps the first `limit` images that fit the byte budget. Pure, so the
    /// rules are unit-tested without a picker.
    static func fit(
        _ images: [ChatImage],
        limit: Int = maxPerMessage,
        byteBudget: Int = maxTotalEncodedBytes
    ) -> FitResult {
        var result = FitResult()
        var bytes = 0
        for image in images {
            guard result.accepted.count < limit else {
                result.droppedForCount += 1
                continue
            }
            let size = image.base64.utf8.count
            guard bytes + size <= byteBudget else {
                result.droppedForSize += 1
                continue
            }
            result.accepted.append(image)
            bytes += size
        }
        return result
    }

    /// Whether a dropped URL looks like something we can attach, so a dropped
    /// folder or a .typ file is ignored instead of raising an error.
    static func isImageFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }
}
/// Decoded thumbnails for the panel, keyed by attachment id. Decoding a saved
/// conversation's images on every re-render would be far too slow (the
/// transcript re-renders with every streamed token), and the bytes never
/// change once attached.
@MainActor
enum ChatImageCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        // Bound both count and bytes: a long chat with many screenshots must
        // not keep every full-resolution decode alive.
        cache.countLimit = 64
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    static func image(for attachment: ChatImage) -> NSImage? {
        let key = attachment.id.uuidString as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let data = Data(base64Encoded: attachment.base64),
              let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: key, cost: data.count)
        return image
    }
}
