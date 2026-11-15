import Foundation

/// Cheap equality and offset helpers for large documents.
///
/// The editor compares the whole document against a saved copy on every
/// keystroke — in `sourceCode.didSet`, `checkUnsavedChanges` and
/// `reconcileTextViewIfNeeded`. `String ==` on two distinct multi-megabyte
/// strings costs tens of milliseconds and cannot stop early when only the
/// tail differs, so three comparisons per keystroke added up to the
/// "typing bogs down in long documents" symptom.
///
/// Every helper here is ordered cheapest-check-first:
/// 1. **Length** — an O(1) `utf16.count`. A single typed character changes the
///    length, so the common case resolves without touching the contents.
/// 2. **Contiguous byte compare** — when both strings expose a contiguous
///    UTF-8 buffer, `memcmp` runs at memory bandwidth instead of walking
///    grapheme clusters.
/// 3. **Fallback** — `String ==` only when neither fast path applies.
enum TextEquality {
    /// UTF-16 length, the unit every `NSRange` in the editor is measured in.
    @inline(__always)
    static func length(_ s: String) -> Int {
        s.utf16.count
    }

    /// True only if `a` and `b` hold exactly the same text.
    ///
    /// Not `@inline(__always)`: it is called from a handful of sites, and the
    /// body is large enough that inlining it everywhere would bloat them.
    static func equal(_ a: String, _ b: String) -> Bool {
        // 1. Length gate. O(1), and the usual answer while typing.
        guard a.utf16.count == b.utf16.count else { return false }
        // 2. Byte compare when both are contiguous UTF-8.
        if let fast = compareContiguous(a, b) { return fast }
        // 3. General case.
        return a == b
    }

    /// `memcmp` over contiguous UTF-8 when available. Returns `nil` when the
    /// strings do not expose contiguous buffers, so the caller can fall back.
    private static func compareContiguous(_ a: String, _ b: String) -> Bool? {
        let inner: Bool?? = a.utf8.withContiguousStorageIfAvailable { bufferA in
            b.utf8.withContiguousStorageIfAvailable { bufferB in
                guard bufferA.count == bufferB.count else { return false }
                guard let pa = bufferA.baseAddress, let pb = bufferB.baseAddress else {
                    return bufferA.isEmpty
                }
                return memcmp(pa, pb, bufferA.count) == 0
            }
        }
        return inner.flatMap { $0 }
    }

    // MARK: - Trimmed comparison

    /// The UTF-16 range of `s` with leading and trailing whitespace/newlines
    /// removed, without copying the string.
    ///
    /// Walks only the whitespace at each end, so it is O(whitespace) rather
    /// than O(document).
    static func trimmedRange(of s: String) -> NSRange {
        let ns = s as NSString
        let length = ns.length
        let whitespace = CharacterSet.whitespacesAndNewlines
        var start = 0
        while start < length,
              let scalar = Unicode.Scalar(ns.character(at: start)),
              whitespace.contains(scalar) {
            start += 1
        }
        var end = length
        while end > start,
              let scalar = Unicode.Scalar(ns.character(at: end - 1)),
              whitespace.contains(scalar) {
            end -= 1
        }
        return NSRange(location: start, length: end - start)
    }

    /// True when `a` and `b` are equal after trimming surrounding whitespace.
    ///
    /// Length is checked before any content is read, so two documents that
    /// differ in size — the normal result of typing — resolve in O(1).
    static func equalIgnoringSurroundingWhitespace(_ a: String, _ b: String) -> Bool {
        let ra = trimmedRange(of: a)
        let rb = trimmedRange(of: b)
        guard ra.length == rb.length else { return false }
        let sliceA = (a as NSString).substring(with: ra)
        let sliceB = (b as NSString).substring(with: rb)
        return equal(sliceA, sliceB)
    }

    // MARK: - UTF-16 offset math

    /// Converts a UTF-16 offset into a `String.Index` in O(1) for the
    /// contiguous cases and O(distance) otherwise.
    ///
    /// `String` indices are grapheme-cluster based, so `String.count` and
    /// `index(_:offsetBy:)` walk every cluster in the string. On a
    /// 1.6 MB document that measured ~100 ms and ~50 ms respectively, once per
    /// keystroke, in the completion providers. Going through `utf16` keeps the
    /// walk in code-unit space and, for a UTF-16-backed string, is a direct
    /// index.
    static func index(utf16Offset offset: Int, in s: String) -> String.Index? {
        let utf16 = s.utf16
        guard offset >= 0, offset <= utf16.count else { return nil }
        return String.Index(utf16.index(utf16.startIndex, offsetBy: offset), within: s)
    }

    /// UTF-16 offset of a `String.Index`, clamped into `s`.
    static func utf16Offset(of index: String.Index, in s: String) -> Int {
        index.samePosition(in: s.utf16)?.utf16Offset(in: s) ?? s.utf16.count
    }
}
