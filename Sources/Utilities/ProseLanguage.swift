import Foundation
import NaturalLanguage

/// Which language a piece of prose is in, and the few word lists the
/// writing tools need per language.
///
/// Most checks are language-neutral (numbers, references, sentence length,
/// copied passages). A handful need words: negations ("not" / "nicht" /
/// "pas"), strength words ("must" / "muss"), number words ("fifty" /
/// "fünfzig"). Those live in a `Pack` per language; a language without a
/// pack still gets every neutral check. Detection is Apple's on-device
/// `NLLanguageRecognizer`.
enum ProseLanguage {

    struct Pack: Sendable {
        let language: NLLanguage
        /// Words that negate. Matched lowercased, whole words.
        let negations: Set<String>
        /// Word endings that negate ("n't"), counted as one negation.
        let negationSuffixes: [String]
        /// Word beginnings that negate (French "n'est"), counted as one.
        var negationPrefixes: [String] = []
        /// Words that make a statement stronger: losing one weakens it.
        let qualifiers: Set<String>
        /// Spelled-out numbers → digits. Only unambiguous words: "un"/"ein"
        /// are also articles, so they are left out.
        let numberWords: [String: String]
        /// Words that, opening a sentence, refer back to the sentence
        /// before ("This", "However") — a sentence starting with one reads
        /// wrong when moved away from its context.
        var referringStarters: Set<String> = []
    }

    static let english = Pack(
        language: .english,
        negations: ["not", "no", "never", "none", "nor", "neither", "nothing", "nobody", "nowhere", "without", "cannot"],
        negationSuffixes: ["n't", "n\u{2019}t"],
        qualifiers: ["must", "shall", "always", "only", "required", "mandatory"],
        numberWords: [
            "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6",
            "seven": "7", "eight": "8", "nine": "9", "ten": "10", "eleven": "11", "twelve": "12",
            "thirteen": "13", "fourteen": "14", "fifteen": "15", "sixteen": "16", "seventeen": "17",
            "eighteen": "18", "nineteen": "19", "twenty": "20", "thirty": "30", "forty": "40",
            "fifty": "50", "sixty": "60", "seventy": "70", "eighty": "80", "ninety": "90",
            "hundred": "100", "thousand": "1000", "million": "1000000",
        ],
        referringStarters: ["this", "these", "that", "those", "it", "its", "they", "them", "their", "such",
                            "however", "therefore", "thus", "also", "moreover", "furthermore", "then",
                            "here", "there", "besides", "likewise", "similarly", "consequently", "otherwise", "instead"]
    )

    static let german = Pack(
        language: .german,
        negations: ["nicht", "kein", "keine", "keinen", "keinem", "keiner", "keines", "nie", "niemals",
                    "nichts", "niemand", "ohne", "weder", "nirgends"],
        negationSuffixes: [],
        qualifiers: ["muss", "müssen", "musst", "immer", "nur", "erforderlich", "zwingend", "stets"],
        numberWords: [
            "null": "0", "zwei": "2", "drei": "3", "vier": "4", "fünf": "5", "sechs": "6", "sieben": "7",
            "acht": "8", "neun": "9", "zehn": "10", "elf": "11", "zwölf": "12", "zwanzig": "20",
            "dreißig": "30", "vierzig": "40", "fünfzig": "50", "sechzig": "60", "siebzig": "70",
            "achtzig": "80", "neunzig": "90", "hundert": "100", "tausend": "1000", "million": "1000000",
        ],
        referringStarters: ["dies", "diese", "dieser", "dieses", "es", "sie", "deshalb", "daher", "jedoch",
                            "außerdem", "auch", "dann", "somit", "dabei", "dadurch", "trotzdem", "stattdessen"]
    )

    static let french = Pack(
        language: .french,
        negations: ["ne", "pas", "non", "jamais", "rien", "aucun", "aucune", "sans", "ni", "nullement", "guère"],
        negationSuffixes: [],
        negationPrefixes: ["n'", "n\u{2019}"],
        qualifiers: ["doit", "doivent", "toujours", "seulement", "uniquement", "obligatoire", "exigé"],
        numberWords: [
            "zéro": "0", "deux": "2", "trois": "3", "quatre": "4", "cinq": "5", "six": "6", "sept": "7",
            "huit": "8", "neuf": "9", "dix": "10", "onze": "11", "douze": "12", "vingt": "20", "trente": "30",
            "quarante": "40", "cinquante": "50", "soixante": "60", "cent": "100", "mille": "1000", "million": "1000000",
        ],
        referringStarters: ["ce", "cela", "ceci", "ces", "cette", "il", "elle", "ils", "elles", "cependant",
                            "donc", "ainsi", "aussi", "ensuite", "puis", "toutefois", "pourtant", "sinon"]
    )

    static let spanish = Pack(
        language: .spanish,
        negations: ["no", "nunca", "jamás", "nada", "nadie", "ningún", "ninguno", "ninguna", "sin", "ni", "tampoco"],
        negationSuffixes: [],
        qualifiers: ["debe", "deben", "siempre", "solo", "sólo", "únicamente", "obligatorio"],
        numberWords: [
            "cero": "0", "dos": "2", "tres": "3", "cuatro": "4", "cinco": "5", "seis": "6", "siete": "7",
            "ocho": "8", "nueve": "9", "diez": "10", "once": "11", "doce": "12", "veinte": "20",
            "treinta": "30", "cuarenta": "40", "cincuenta": "50", "sesenta": "60", "cien": "100",
            "mil": "1000", "millón": "1000000",
        ],
        referringStarters: ["esto", "este", "esta", "estos", "estas", "eso", "ello", "además", "también",
                            "entonces", "así", "pero", "sino", "asimismo"]
    )

    static let packs: [NLLanguage: Pack] = [
        .english: english, .german: german, .french: french, .spanish: spanish,
    ]

    /// Fewer characters than this can't be classified reliably; such text
    /// takes the surrounding (document) language.
    static let minimumCharacters = 40

    /// The dominant language of `text`, or `fallback` when it is too short
    /// or unclear.
    static func detect(_ text: String, fallback: NLLanguage? = nil) -> NLLanguage? {
        guard text.count >= minimumCharacters else { return fallback }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= 0.5 else { return fallback }
        return language
    }

    static func pack(for language: NLLanguage?) -> Pack? {
        language.flatMap { packs[$0] }
    }

    /// Negation words in `text` under `pack`: whole words, plus endings
    /// ("isn't") and elisions ("n'est") counted as "not".
    static func negations(in text: String, pack: Pack) -> [String] {
        text.lowercased()
            .split { !($0.isLetter || $0 == "'" || $0 == "\u{2019}") }
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "'\u{2019}")) }
            .compactMap { word in
                if pack.negationSuffixes.contains(where: { word.hasSuffix($0) }) { return "not" }
                if pack.negationPrefixes.contains(where: { word.hasPrefix($0) && word.count > $0.count }) { return "not" }
                return pack.negations.contains(word) ? word : nil
            }
    }

    /// English name for a language, for messages ("German").
    static func name(_ language: NLLanguage?) -> String {
        guard let language else { return "unknown language" }
        return Locale(identifier: "en").localizedString(forLanguageCode: language.rawValue) ?? language.rawValue
    }

    // MARK: Words

    /// Scripts written without spaces between words.
    static func needsTokenizer(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, // Hiragana, Katakana
                 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, // CJK
                 0x0E00...0x0EFF, // Thai, Lao
                 0x1000...0x109F, // Myanmar
                 0x1780...0x17FF: // Khmer
                return true
            default:
                return false
            }
        }
    }

    /// Lowercased words of `text`. Whitespace and punctuation split words in
    /// most scripts; Chinese, Japanese, Thai and similar go through
    /// `NLTokenizer`, which knows where their words end.
    static func words(_ text: String) -> [String] {
        guard needsTokenizer(text) else {
            return text.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
        }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var result: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let word = text[range].lowercased()
            if word.contains(where: { $0.isLetter || $0.isNumber }) { result.append(word) }
            return true
        }
        return result
    }
}
