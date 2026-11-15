import Foundation

/// Reads a file for background scans (the semantic index, find-in-project)
/// without ever getting in the way of whoever is writing it.
///
/// Background readers used to open files with plain `Data(contentsOf:)`,
/// which works, but says nothing about the two properties the project
/// actually needs:
///
/// - **No locks.** The read takes no exclusive or shared lock that a writer
///   (or another app) would have to honor, and never coordinates through
///   `NSFileCoordinator`. A save in progress can at worst cost the bytes
///   that were read; nothing ever waits on the reader.
/// - **Lossy, never fatal.** A file that vanished, shrank mid-read or could
///   not be opened yields `nil` — the caller skips it and catches it on the
///   next pass — instead of failing the whole scan. Decoding is the caller's
///   job; `TextFileEncoding.decode` is total, so a torn read produces lossy
///   text rather than an error.
enum LossyFileReader {
    struct Reading: Sendable {
        let data: Data
        /// The file has (or may have) more bytes than were read: the read was
        /// cut off at `maxBytes`. Callers must not treat partial content as
        /// the file's full content.
        let truncated: Bool
    }

    /// Reads up to `maxBytes` of `url`. `nil` when the file could not be
    /// opened at all (it vanished, or it is not readable) — skip it and
    /// catch it on the next pass.
    static func read(_ url: URL, maxBytes: Int) -> Reading? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        // One bounded read: asks for maxBytes + 1 so a file that is exactly
        // maxBytes long is not misreported as truncated, and a file that is
        // still growing just gets its first maxBytes read (truncated).
        let data: Data
        do {
            data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        } catch {
            return nil
        }
        guard !data.isEmpty else { return nil }

        if data.count > maxBytes {
            return Reading(data: Data(data.prefix(maxBytes)), truncated: true)
        }
        return Reading(data: data, truncated: false)
    }
}
