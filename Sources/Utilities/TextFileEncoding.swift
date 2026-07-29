import Foundation

/// Encoding-agnostic text decoding for user documents.
///
/// Files are decoded in order of confidence:
/// 1. An explicit byte-order mark (UTF-8, UTF-32 LE/BE, UTF-16 LE/BE) wins outright.
/// 2. Without a BOM, strict UTF-8 is attempted first (the overwhelmingly common case).
/// 3. A NUL-byte parity heuristic detects BOM-less UTF-16, which strict UTF-8 rejects.
/// 4. Windows-1252 covers the common Windows "ANSI" files (superset of ISO Latin-1,
///    with the € / curly-quote / smart-dash bytes that Latin-1 leaves undefined).
/// 5. ISO Latin-1 maps every byte and therefore never fails.
///
/// Decoding always succeeds; the returned encoding is what was actually used, so
/// callers can display it. Saving stays UTF-8 — the Typst CLI requires UTF-8 sources,
/// so normalizing on save is the correct behavior for this editor.
enum TextFileEncoding {
    struct Decoded {
        let text: String
        let encoding: String.Encoding
        /// Human-readable name for status display (e.g. "UTF-8", "UTF-16 (LE)", "Windows-1252").
        let encodingName: String
    }

    static func decode(_ data: Data) -> Decoded {
        // 1. Byte-order marks (longest first — the UTF-32 prefixes overlap nothing here,
        //    but checking 4-byte BOMs before 2-byte ones keeps it unambiguous).
        if data.starts(with: [0xEF, 0xBB, 0xBF]),
           let text = String(data: data.dropFirst(3), encoding: .utf8) {
            return Decoded(text: text, encoding: .utf8, encodingName: "UTF-8 (BOM)")
        }
        if data.starts(with: [0x00, 0x00, 0xFE, 0xFF]),
           let text = String(data: data.dropFirst(4), encoding: .utf32BigEndian) {
            return Decoded(text: text, encoding: .utf32BigEndian, encodingName: "UTF-32 (BE)")
        }
        if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]),
           let text = String(data: data.dropFirst(4), encoding: .utf32LittleEndian) {
            return Decoded(text: text, encoding: .utf32LittleEndian, encodingName: "UTF-32 (LE)")
        }
        if data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) {
            return Decoded(text: text, encoding: .utf16BigEndian, encodingName: "UTF-16 (BE)")
        }
        if data.starts(with: [0xFF, 0xFE]),
           let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) {
            return Decoded(text: text, encoding: .utf16LittleEndian, encodingName: "UTF-16 (LE)")
        }

        // 2. Strict UTF-8 — nil on any invalid sequence, no replacement characters.
        //    NUL-free is required: ASCII text encoded as UTF-16 ("c\0c\0…") decodes
        //    as *valid* UTF-8 with a NUL between every character, which is exactly
        //    the BOM-less UTF-16 case the heuristic below must catch. Real source
        //    text never contains NULs, so rejecting them here is safe.
        if let text = String(data: data, encoding: .utf8), !text.contains("\0") {
            return Decoded(text: text, encoding: .utf8, encodingName: "UTF-8")
        }

        // 3. BOM-less UTF-16 heuristic: ASCII-range text encoded as UTF-16 has a NUL
        //    byte on every other position. Require an even byte count, a strong NUL
        //    parity bias, and almost no NULs on the other parity (rules out binary).
        if let (text, name) = decodeBOMLessUTF16(data) {
            return Decoded(text: text, encoding: name == "UTF-16 (LE)" ? .utf16LittleEndian : .utf16BigEndian, encodingName: name)
        }

        // 4. Windows-1252 ("ANSI"). String(data:encoding:) for .windowsCP1252 maps
        //    the 5 undefined bytes (0x81, 0x8D, 0x8F, 0x90, 0x9D) leniently, so in
        //    practice this always succeeds; Latin-1 remains as a hard guarantee.
        if let text = String(data: data, encoding: .windowsCP1252) {
            return Decoded(text: text, encoding: .windowsCP1252, encodingName: "Windows-1252")
        }

        let text = String(data: data, encoding: .isoLatin1) ?? ""
        return Decoded(text: text, encoding: .isoLatin1, encodingName: "ISO Latin-1")
    }

    /// Convenience for reading a file with automatic encoding detection.
    static func string(from url: URL) throws -> Decoded {
        let data = try Data(contentsOf: url)
        return decode(data)
    }

    private static func decodeBOMLessUTF16(_ data: Data) -> (String, String)? {
        let count = data.count
        guard count >= 4, count % 2 == 0 else { return nil }

        var nulsAtEven = 0
        var nulsAtOdd = 0
        var index = 0
        for byte in data {
            if byte == 0 {
                if index % 2 == 0 { nulsAtEven += 1 } else { nulsAtOdd += 1 }
            }
            index += 1
        }
        let half = count / 2
        // Need a strong bias: >30% NULs on one parity, <2% on the other.
        // Percentages are compared via cross-multiplication to avoid integer
        // truncation on small inputs.
        if nulsAtOdd * 100 > half * 30, nulsAtEven * 100 < half * 2,
           let text = String(data: data, encoding: .utf16LittleEndian) {
            return (text, "UTF-16 (LE)")
        }
        if nulsAtEven * 100 > half * 30, nulsAtOdd * 100 < half * 2,
           let text = String(data: data, encoding: .utf16BigEndian) {
            return (text, "UTF-16 (BE)")
        }
        return nil
    }
}
