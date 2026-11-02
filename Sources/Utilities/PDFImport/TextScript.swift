import Foundation

/// Script facts the layout and emission code needs: which direction a line
/// runs, and which scripts are written without spaces between words.
///
/// Extracted PDF text arrives in *visual* order, so an Arabic or Hebrew line
/// comes out with its words reversed; and a line break inside Chinese, Thai
/// or Khmer text must not turn into a space.
enum TextScript {

    /// Letters of scripts written right to left.
    static func isRightToLeft(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0590...0x05FF,      // Hebrew
             0x0600...0x06FF,      // Arabic
             0x0700...0x074F,      // Syriac
             0x0750...0x077F,      // Arabic Supplement
             0x0780...0x07BF,      // Thaana
             0x07C0...0x07FF,      // NKo
             0x0800...0x083F,      // Samaritan
             0x0840...0x085F,      // Mandaic
             0x08A0...0x08FF,      // Arabic Extended-A
             0xFB1D...0xFB4F,      // Hebrew presentation forms
             0xFB50...0xFDFF,      // Arabic presentation forms A
             0xFE70...0xFEFF,      // Arabic presentation forms B
             0x10800...0x10FFF,    // Old Italic … Old South Arabian
             0x1E800...0x1EFFF:    // Adlam, Arabic math
            return true
        default:
            return false
        }
    }

    /// Letters of scripts that run left to right.
    private static func isLeftToRightLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0041...0x005A, 0x0061...0x007A,        // Latin
             0x00C0...0x024F,                          // Latin extended
             0x0370...0x03FF, 0x1F00...0x1FFF,         // Greek
             0x0400...0x04FF, 0x0500...0x052F,         // Cyrillic
             0x0530...0x058F,                          // Armenian
             0x0900...0x0DFF,                          // Indic
             0x0E00...0x0EFF,                          // Thai, Lao
             0x1000...0x109F, 0x1780...0x17FF,         // Myanmar, Khmer
             0x3040...0x30FF, 0x3400...0x4DBF,         // kana, Han
             0x4E00...0x9FFF, 0xAC00...0xD7AF,         // Han, Hangul
             0xF900...0xFAFF, 0xFF00...0xFFEF:         // compatibility forms
            return CharacterSet.letters.contains(scalar)
        default:
            return CharacterSet.letters.contains(scalar) && !isRightToLeft(scalar)
        }
    }

    /// True when a line is mostly right-to-left, so its words were extracted
    /// in reverse (visual) order.
    static func isRightToLeftLine(_ text: String) -> Bool {
        var rtl = 0, ltr = 0
        for scalar in text.unicodeScalars {
            if isRightToLeft(scalar) { rtl += 1 }
            else if isLeftToRightLetter(scalar) { ltr += 1 }
        }
        return rtl > 0 && rtl >= ltr
    }

    /// Scripts written without spaces between words: a line break inside
    /// them is not a word gap. Han, kana and Hangul mostly mix freely;
    /// Thai, Lao, Khmer and Myanmar break anywhere.
    static func hasNoWordSpacing(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0E00...0x0EFF,                          // Thai, Lao
             0x1000...0x109F, 0x1780...0x17FF,         // Myanmar, Khmer
             0x2E80...0x2FFF,                          // radicals
             0x3000...0x303F,                          // CJK punctuation
             0x3040...0x30FF,                          // kana
             0x3400...0x4DBF, 0x4E00...0x9FFF,         // Han
             0xF900...0xFAFF, 0xFF00...0xFFEF,         // CJK compatibility
             0x20000...0x2FA1F:                        // Han extensions
            return true
        default:
            return false
        }
    }

    /// True when a line break between these two characters must not become a
    /// space (a Chinese sentence split by the line wrapping).
    static func joinsWithoutSpace(after previous: Character, before next: Character) -> Bool {
        guard let a = previous.unicodeScalars.last, let b = next.unicodeScalars.first else { return false }
        // Both sides in a script without word spacing.
        if hasNoWordSpacing(a) && hasNoWordSpacing(b) { return true }
        // A CJK run ending or starting at a Latin word keeps its own spacing,
        // which the extractor already recorded as a real space.
        return false
    }
}
