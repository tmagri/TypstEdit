import Foundation

/// Spots a model stuck in a degenerate loop: the same passage streamed out
/// again and again, byte for byte, until the reply limit runs out. Small and
/// local models do this most (a sampling collapse), but any model can.
///
/// Fed incrementally with streamed fragments. Every `checkInterval` bytes it
/// asks whether the most recent output is one unit repeated back to back,
/// using the prefix function of the reversed tail window — the shortest
/// period of every suffix in one O(n) pass, so a check stays cheap even with
/// long units. Only exact repeats count: prose that merely sounds similar,
/// or a list whose lines differ by a number, never trips it.
struct RepetitionDetector {
    struct Loop: Equatable {
        /// One copy of the repeated passage (rotated to wherever the scan
        /// caught it).
        let unit: String
        /// How many full copies are in a row at the end of the output.
        let repeats: Int
        /// UTF-8 offset in everything fed so far where the repetition starts.
        /// Output up to `start + unit byte length` is the text before the
        /// loop plus one copy — the part worth keeping.
        let start: Int
        let unitByteLength: Int
    }

    /// Longest unit recognised. A loop over a whole paragraph is common, so
    /// this is generous; the window has to hold `minRepeats` copies of it.
    static let maxPeriod = 2_000
    /// Bytes of output kept for scanning.
    static let window = 8_192
    static let checkInterval = 256
    static let minRepeats = 3
    /// Repeated run, in bytes, before it counts — so a short legitimate
    /// repeat (a few identical table rows) is left alone.
    static let minCoverage = 600
    /// Very short units (`0, `, `| `, a lone newline) also appear in real
    /// output — separator lines, zero matrices — so they need a longer run.
    static let shortPeriod = 16
    static let shortPeriodCoverage = 1_500

    private var tail: [UInt8] = []
    private var totalBytes = 0
    private var sinceCheck = 0

    /// Adds a fragment. Returns the loop once one is established.
    mutating func feed(_ fragment: String) -> Loop? {
        let bytes = Array(fragment.utf8)
        guard !bytes.isEmpty else { return nil }
        tail.append(contentsOf: bytes)
        totalBytes += bytes.count
        sinceCheck += bytes.count
        if tail.count > Self.window {
            tail.removeFirst(tail.count - Self.window)
        }
        guard sinceCheck >= Self.checkInterval else { return nil }
        sinceCheck = 0
        return Self.trailingLoop(in: tail, totalBytes: totalBytes)
    }

    /// The longest periodic suffix of `tail` that qualifies as a loop.
    static func trailingLoop(in tail: [UInt8], totalBytes: Int) -> Loop? {
        let n = tail.count
        guard n >= minCoverage else { return nil }
        let reversed = Array(tail.reversed())
        // pi[i]: length of the longest proper border of reversed[0...i].
        var pi = [Int](repeating: 0, count: n)
        for i in 1..<n {
            var k = pi[i - 1]
            while k > 0 && reversed[i] != reversed[k] { k = pi[k - 1] }
            if reversed[i] == reversed[k] { k += 1 }
            pi[i] = k
        }
        // A prefix of `reversed` is a suffix of `tail`; its shortest period
        // is its length minus its longest border.
        var length = n
        while length >= minCoverage {
            let period = length - pi[length - 1]
            let needed = period < shortPeriod ? shortPeriodCoverage : minCoverage
            if period <= maxPeriod, length / period >= minRepeats, length >= needed {
                // Units are whole bytes of the tail; snap to scalar
                // boundaries so the reported unit never shows a broken
                // character.
                let unitBytes = Array(tail[(n - period)...])
                let unit = String(decoding: unitBytes, as: UTF8.self)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FFFD}"))
                return Loop(
                    unit: unit,
                    repeats: length / period,
                    start: totalBytes - length,
                    unitByteLength: period
                )
            }
            length -= 1
        }
        return nil
    }

    /// `text` cut back to what came before the loop plus one copy of the
    /// unit. `text` must be the same output the detector was fed.
    static func keptPrefix(of text: String, before loop: Loop) -> String {
        let keep = min(text.utf8.count, max(0, loop.start + loop.unitByteLength))
        let bytes = Array(text.utf8.prefix(keep))
        return String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FFFD}"))
    }

    /// A short, single-line preview of the unit for status lines and notes.
    static func preview(_ unit: String, limit: Int = 80) -> String {
        let flat = unit
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if flat.isEmpty { return "(whitespace)" }
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }
}
