import Foundation
import NaturalLanguage

/// Checks prose against the mechanical rules of ASD-STE100 Simplified
/// Technical English — the rules a scanner can see exactly: sentence
/// length, contractions, weak modals, perfect tenses, ", making…" clauses,
/// semicolons, dashes, Latin abbreviations, hype words, trailing
/// conditions, passive voice, synonym rotation, spelling variants of one
/// term, and acronyms used before they are spelled out.
///
/// The regex rules are ported from `evals/ste_lint.py` of
/// github.com/AminBlg/SimpleEnglish (MIT, © 2026 AminBlg), adapted to
/// Typst/Markdown sources; passive voice uses Apple's on-device
/// `NLTagger`. It measures rule obedience, not word choice or meaning: the
/// STE dictionary itself may not be reproduced, so it is not checked.
enum WritingChecker {

    enum TextType: String, Sendable {
        /// Instructions get 20 words, descriptions 25; each sentence is
        /// classified by whether it starts with a verb.
        case auto
        case procedural
        case descriptive
    }

    enum Rule: String, CaseIterable, Sendable {
        case sentenceLength, trailingCondition, passiveVoice, weakModal, perfectTense, ingClause
        case contraction, semicolon, dash, latinAbbreviation, hypeWord
        case synonymRotation, termVariant, undefinedAcronym

        var title: String {
            switch self {
            case .sentenceLength: return "Sentence too long"
            case .trailingCondition: return "Condition after the command"
            case .passiveVoice: return "Passive voice"
            case .weakModal: return "Weak modal (should/would/may/might/could)"
            case .perfectTense: return "Perfect tense"
            case .ingClause: return "\", -ing\" clause"
            case .contraction: return "Contraction"
            case .semicolon: return "Semicolon"
            case .dash: return "Dash joining two thoughts"
            case .latinAbbreviation: return "Latin abbreviation"
            case .hypeWord: return "Hype or filler word"
            case .synonymRotation: return "Several words for one meaning"
            case .termVariant: return "Same term spelled differently"
            case .undefinedAcronym: return "Acronym not spelled out at first use"
            }
        }

        var fix: String {
            switch self {
            case .sentenceLength: return "Split it: at most 20 words for an instruction, 25 for a description."
            case .trailingCondition: return "Put the condition first: \"If X, do Y.\""
            case .passiveVoice: return "Use active voice: say who or what does the action."
            case .weakModal: return "Use can, must or will, or state the fact."
            case .perfectTense: return "Use the simple present or past."
            case .ingClause: return "Make it a separate sentence with its own subject and verb."
            case .contraction: return "Write the full form: do not, it is."
            case .semicolon: return "Split it into two sentences."
            case .dash: return "Use a period, a comma, or a word such as \"because\"."
            case .latinAbbreviation: return "Write \"for example\" or \"that is\", or list all items."
            case .hypeWord: return "Delete it, use the plain word shown, or state the measured fact."
            case .synonymRotation: return "Use one word for one meaning in the whole document."
            case .termVariant: return "Pick one spelling and use it everywhere."
            case .undefinedAcronym: return "Spell it out at first use: \"Full Name (ACR)\"."
            }
        }
    }

    struct Finding: Equatable, Sendable {
        let rule: Rule
        let line: Int
        /// The matched words, or the sentence (clipped).
        let text: String
        var detail: String? = nil
    }

    struct Report: Sendable {
        var findings: [Finding] = []
        var words = 0
        var sentences = 0
        var longestSentence = 0
        /// Words and findings per section heading, for "worst sections".
        var sections: [(entry: DocumentOutline.Entry, words: Int, findings: Int)] = []
        /// Paragraphs per detected language, most first.
        var languages: [(name: String, paragraphs: Int)] = []
        /// Paragraphs the English-only STE rules skipped.
        var nonEnglishParagraphs = 0

        var meanSentence: Double { sentences == 0 ? 0 : Double(words) / Double(sentences) }
    }

    static let proceduralLimit = 20
    static let descriptiveLimit = 25

    // MARK: Patterns

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
    private static let apostrophe = "['\u{2019}]"
    private static let contractionRegex = regex("\\b\\w+\(apostrophe)(?:t|ll|re|ve|d)\\b|\\b(?:it|that|there|what|here|let|he|she|who)\(apostrophe)s\\b")
    /// "May 2024" is a month, not a modal.
    private static let modalRegex = regex("\\b(?:should|would|might|could)\\b|\\bmay\\b(?!\\s+\\d)")
    private static let perfectRegex = regex("\\b(?:has|have|had)\\s+been\\b|\\b(?:has|have)\\s+\\w+ed\\b")
    private static let ingRegex = regex(",\\s*(?:mak|allow|enabl|ensur|highlight|creat|provid|offer|help|reduc|improv|lead|caus|result)ing\\b")
    private static let dashRegex = try! NSRegularExpression(pattern: "—|(?<!\\d)–(?!\\d)|(?<= )--(?= )|(?<=[^\\s\\d]{2}) - (?=[^\\s\\d]{2})")
    private static let latinRegex = regex("\\b(?:e\\.g\\.|i\\.e\\.|etc\\.?)(?=[\\s,)]|$)|\\bvs\\.?(?=\\s)")
    private static let trailingConditionRegex = regex("\\s(?:if|when|unless)\\s")

    /// Hype and filler words with the plain replacement, from the
    /// SimpleEnglish lexicon (`evals/slop.tsv` and `ste_lint.py`'s core list).
    static let hypeWords: [(term: String, swap: String)] = [
        ("delve", "examine"), ("pivotal", "important"), ("tapestry", "delete"), ("vibrant", "delete"),
        ("robust", "give the measured property"), ("intricate", "complex"), ("crucial", "important"),
        ("realm", "area"), ("groundbreaking", "new"), ("seamless", "delete"), ("seamlessly", "delete"),
        ("transformative", "delete"), ("testament", "delete"), ("leverage", "use"), ("cutting-edge", "new"),
        ("in conclusion", "delete"), ("showcase", "show"), ("foster", "help"), ("furthermore", "also"),
        ("underscore", "show"), ("synergy", "delete"), ("interplay", "interaction"), ("harness", "use"),
        ("enhance", "improve"), ("elevate", "increase"), ("moreover", "also"), ("streamline", "make simpler"),
        ("profound", "large"), ("multifaceted", "name the parts"), ("landscape", "area"),
        ("game-changer", "delete"), ("unleash", "release"), ("paramount", "most important"),
        ("nuanced", "delete"), ("meticulous", "careful"), ("in order to", "to"), ("holistic", "full"),
        ("revolutionize", "change"), ("empower", "let"), ("embark", "start"), ("consequently", "as a result"),
        ("unprecedented", "new"), ("paradigm", "model"), ("innovative", "new"), ("enduring", "permanent"),
        ("unparalleled", "delete"), ("remarkable", "delete"), ("emphasize", "show"), ("commendable", "good"),
        ("bustling", "busy"), ("at the end of the day", "delete"), ("in summary", "delete"),
        ("due to the fact that", "because"), ("state-of-the-art", "new"), ("renowned", "known"),
        ("nestled", "in"), ("endeavor", "try"), ("elucidate", "explain"), ("bolster", "support"),
        ("notably", "delete"), ("navigate", "go to"), ("ever-evolving", "delete"), ("boast", "have"),
        ("that being said", "but"), ("notwithstanding", "but"), ("simply", "delete"),
        ("effortlessly", "delete"), ("utilize", "use"), ("comprehensive", "full"), ("powerful", "delete"),
        ("facilitate", "help"), ("plethora", "many"), ("myriad", "many"),
    ]
    private static let hypeRegex: NSRegularExpression = {
        // Stems, so "leverage" also catches "leveraging", "delve" "delving".
        let alternatives = hypeWords.map(\.term)
            .map(hypeStem)
            .sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: " ", with: "\\s+") + "\\w*" }
        return regex("\\b(?:" + alternatives.joined(separator: "|") + ")\\b")
    }()

    /// "leverage" → "leverag": a final "e" is dropped from single words so
    /// the stem matches every inflection.
    static func hypeStem(_ term: String) -> String {
        guard !term.contains(" "), term.hasSuffix("e"), term.count > 4 else { return term }
        return String(term.dropLast())
    }

    /// Groups of words that the STE "one word, one meaning" rule says not to
    /// rotate between (from ste_lint.py).
    static let rotationSets: [(name: String, stems: [String])] = [
        ("check / verify / confirm / validate / ensure", ["check", "verify", "confirm", "validate", "ensure"]),
        ("config / configuration / settings", ["config", "configuration", "settings"]),
    ]

    private static let beForms: Set<String> = ["am", "is", "are", "was", "were", "be", "been", "being"]
    private static let irregularParticiples: Set<String> = [
        "done", "made", "written", "given", "taken", "shown", "seen", "known", "built", "sent", "kept",
        "found", "held", "brought", "bought", "caught", "taught", "thought", "told", "sold", "left", "lost",
        "meant", "paid", "said", "spent", "understood", "chosen", "driven", "drawn", "eaten", "fallen",
        "forgotten", "frozen", "hidden", "spoken", "stolen", "torn", "worn", "broken", "begun", "run",
        "set", "put", "cut", "read", "led", "fed", "met", "won", "struck", "hung", "laid", "sung", "grown",
        "thrown", "blown", "flown", "proven", "shaken", "woken",
    ]
    /// Adjectives that look like participles after "be". "is used" stays
    /// reported: it is the most common passive in technical writing.
    private static let adjectiveExceptions: Set<String> = ["supposed", "able", "tired", "married", "interested"]

    /// Acronyms readers know without a definition.
    static let commonAcronyms: Set<String> = [
        "PDF", "URL", "USB", "CPU", "GPU", "RAM", "HTML", "CSS", "OK", "UK", "US", "USA", "EU", "UN", "ID",
        "TV", "AM", "PM", "AI", "FAQ", "PS", "UTC", "GMT", "ISO", "IT", "PC", "CD", "DVD", "GB", "MB", "KB",
        "TB", "HD", "LED", "LCD", "GPS", "SMS", "PIN", "ATM", "DNA", "PHD", "MSC", "BSC", "CEO", "NB", "II",
        "III", "IV", "VI", "VII", "VIII", "IX", "XI", "XII", "CODE", "MATH", "REF",
    ]

    // MARK: Checking

    static func check(_ source: String, isMarkdown: Bool = false, type: TextType = .auto, range: ClosedRange<Int>? = nil) -> Report {
        var lines = ProseText.lines(in: source, isMarkdown: isMarkdown, inline: .placeholder)
        if let range { lines = lines.filter { range.contains($0.number) } }
        let paragraphs = ProseText.paragraphs(from: lines)
        let bodyParagraphs = paragraphs.filter { $0.kind != .heading } // headings are titles, exempt

        var report = Report()
        var findings: [Finding] = []
        var sentences: [ProseText.Sentence] = []

        // STE is a controlled *English*: its grammar rules run only on
        // English paragraphs. Each paragraph is classified on its own, so a
        // German thesis with English quotations is handled correctly; text
        // too short to classify takes the document's language.
        let documentLanguage = ProseLanguage.detect(bodyParagraphs.map(\.text).joined(separator: " "))
        var englishParagraphs: [ProseText.Paragraph] = []
        var languageCounts: [String: Int] = [:]

        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        for paragraph in bodyParagraphs {
            let language = ProseLanguage.detect(paragraph.text, fallback: documentLanguage) ?? .english
            let isEnglish = language == .english
            languageCounts[ProseLanguage.name(language), default: 0] += 1
            if isEnglish { englishParagraphs.append(paragraph) }

            // Sentence rules.
            for sentence in ProseText.sentences(in: [paragraph]) {
                let count = ProseText.wordCount(sentence.text)
                guard count >= 2 else { continue }
                sentences.append(sentence)
                report.sentences += 1
                report.words += count
                report.longestSentence = max(report.longestSentence, count)

                let limit: Int
                switch type {
                case .procedural: limit = proceduralLimit
                case .descriptive: limit = descriptiveLimit
                case .auto: limit = startsWithVerb(sentence.text, tagger: tagger) ? proceduralLimit : descriptiveLimit
                }
                if count > limit {
                    findings.append(Finding(rule: .sentenceLength, line: sentence.line, text: clip(sentence.text),
                                            detail: "\(count) words, limit \(limit)"))
                }
                guard isEnglish else { continue }
                if let match = firstMatch(trailingConditionRegex, in: sentence.text), match.location >= 4,
                   firstMatch(regex("^(?:if|when|unless)\\b"), in: sentence.text) == nil {
                    findings.append(Finding(rule: .trailingCondition, line: sentence.line, text: clip(sentence.text)))
                }
                if let passive = passiveVoice(in: sentence.text) {
                    findings.append(Finding(rule: .passiveVoice, line: sentence.line, text: passive))
                }
            }
        }
        report.languages = languageCounts.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
        report.nonEnglishParagraphs = bodyParagraphs.count - englishParagraphs.count

        // Word rules, located through each paragraph's line map. Dashes and
        // semicolons are punctuation, so they apply in every language.
        let englishWordRules: [(Rule, NSRegularExpression)] = [
            (.contraction, contractionRegex), (.weakModal, modalRegex), (.perfectTense, perfectRegex),
            (.ingClause, ingRegex), (.latinAbbreviation, latinRegex), (.hypeWord, hypeRegex),
        ]
        let englishSet = Set(englishParagraphs.map(\.startLine))
        for paragraph in bodyParagraphs {
            let text = paragraph.text
            let range = NSRange(location: 0, length: (text as NSString).length)
            let rules = [(Rule.dash, dashRegex)] + (englishSet.contains(paragraph.startLine) ? englishWordRules : [])
            for (rule, regex) in rules {
                for match in regex.matches(in: text, range: range) {
                    let matched = (text as NSString).substring(with: match.range).trimmingCharacters(in: .whitespaces)
                    var detail: String?
                    if rule == .hypeWord {
                        let lower = matched.lowercased()
                        if let swap = hypeWords.first(where: { lower.hasPrefix(hypeStem($0.term)) })?.swap {
                            detail = swap == "delete" ? "delete it" : "use \"\(swap)\""
                        }
                    }
                    findings.append(Finding(rule: rule, line: paragraph.line(at: match.range.location),
                                            text: matched, detail: detail))
                }
            }
            for (offset, character) in text.utf16.enumerated() where character == UInt16(UInt8(ascii: ";")) {
                findings.append(Finding(rule: .semicolon, line: paragraph.line(at: offset), text: ";"))
            }
        }

        // Document rules. Term spelling and acronyms are language-neutral.
        findings += synonymRotation(in: englishParagraphs)
        findings += termVariants(in: bodyParagraphs)
        findings += undefinedAcronyms(in: paragraphs)

        report.findings = findings.sorted { $0.line != $1.line ? $0.line < $1.line : $0.rule.rawValue < $1.rule.rawValue }
        report.sections = sectionScores(source: source, sentences: sentences, findings: report.findings)
        return report
    }

    private static func startsWithVerb(_ sentence: String, tagger: NLTagger) -> Bool {
        tagger.string = sentence
        var isVerb = false
        tagger.enumerateTags(in: sentence.startIndex..<sentence.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, _ in
            isVerb = tag == .verb
            return false // first word only
        }
        return isVerb
    }

    /// "is/was/been … + past participle", allowing up to two adverbs in
    /// between ("is often used"). Returns the matched phrase.
    static func passiveVoice(in sentence: String) -> String? {
        let words = sentence.split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
        for (index, word) in words.enumerated() where beForms.contains(word.lowercased()) {
            var next = index + 1
            var skipped = 0
            while next < words.count, skipped < 2, words[next].lowercased().hasSuffix("ly") || ["not", "also", "then", "often", "always", "never"].contains(words[next].lowercased()) {
                next += 1
                skipped += 1
            }
            guard next < words.count else { continue }
            let candidate = words[next].lowercased()
            guard candidate.count > 3, !adjectiveExceptions.contains(candidate) else { continue }
            let looksParticiple = irregularParticiples.contains(candidate)
                || (candidate.hasSuffix("ed") && !candidate.hasSuffix("eed"))
            if looksParticiple {
                return words[index...next].joined(separator: " ")
            }
        }
        return nil
    }

    private static func synonymRotation(in paragraphs: [ProseText.Paragraph]) -> [Finding] {
        var findings: [Finding] = []
        for set in rotationSets {
            var firstUse: [String: (line: Int, text: String)] = [:]
            var order: [String] = []
            for paragraph in paragraphs {
                let text = paragraph.text
                let pattern = regex("\\b(" + set.stems.joined(separator: "|") + ")\\w*\\b")
                for match in pattern.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
                    let stem = (text as NSString).substring(with: match.range(at: 1)).lowercased()
                    if firstUse[stem] == nil {
                        firstUse[stem] = (paragraph.line(at: match.range.location), (text as NSString).substring(with: match.range))
                        order.append(stem)
                    }
                }
            }
            for stem in order.dropFirst() {
                guard let use = firstUse[stem] else { continue }
                findings.append(Finding(rule: .synonymRotation, line: use.line, text: use.text,
                                        detail: "also uses \"\(order[0])\" (\(set.name))"))
            }
        }
        return findings
    }

    /// The same term written as one word, two words and hyphenated
    /// ("data set" / "dataset" / "data-set"), or in different mixed cases
    /// ("GitHub" / "Github"). Reported only when two forms both occur.
    private static func termVariants(in paragraphs: [ProseText.Paragraph]) -> [Finding] {
        // Key: the term with case, spaces and hyphens removed. Forms: how
        // it was written, first use of each.
        var forms: [String: [(form: String, line: Int)]] = [:]
        var order: [String] = []
        func add(_ key: String, _ form: String, _ line: Int) {
            guard key.count >= 4 else { return }
            if forms[key] == nil { order.append(key) }
            if forms[key]?.contains(where: { $0.form == form }) != true {
                forms[key, default: []].append((form, line))
            }
        }
        let stopwords = HeuristicTokenFilter.stopwords
        let wordCharacters = CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "-"))
        for paragraph in paragraphs {
            var offset = 0
            var previous: (word: String, line: Int)?
            for raw in paragraph.text.split(separator: " ") {
                let line = paragraph.line(at: offset)
                offset += (String(raw) as NSString).length + 1
                let word = raw.trimmingCharacters(in: wordCharacters)
                guard word.contains(where: \.isLetter) else { previous = nil; continue }
                let lower = word.lowercased()
                // Case only counts with an inner capital ("GitHub"), so a
                // capital at the start of a sentence is not a variant.
                let form = word.dropFirst().contains(where: \.isUppercase) ? word : lower
                add(lower.replacingOccurrences(of: "-", with: ""), form, line)
                if let previous, !stopwords.contains(previous.word.lowercased()), !stopwords.contains(lower) {
                    add(previous.word.lowercased() + lower, previous.word.lowercased() + " " + lower, previous.line)
                }
                previous = raw.last.map { ",.;:!?".contains($0) } == true ? nil : (word, line)
            }
        }
        var findings: [Finding] = []
        for key in order {
            guard let variants = forms[key], variants.count > 1,
                  // Two words alone are just two words: only a clash with
                  // the joined or hyphenated form counts.
                  variants.contains(where: { !$0.form.contains(" ") }) else { continue }
            let listing = variants.prefix(4).map { "\"\($0.form)\" (line \($0.line))" }.joined(separator: ", ")
            findings.append(Finding(rule: .termVariant, line: variants[1].line, text: variants[1].form, detail: listing))
        }
        return findings
    }

    /// Acronyms (two or more capitals) whose first use has no expansion
    /// next to it — "Full Name (ACR)" or "ACR (full name)".
    private static func undefinedAcronyms(in paragraphs: [ProseText.Paragraph]) -> [Finding] {
        let acronym = try! NSRegularExpression(pattern: "\\b[A-Z][A-Z0-9]*[A-Z][A-Z0-9]*s?\\b")
        var seen = Set<String>()
        var findings: [Finding] = []
        for paragraph in paragraphs {
            let text = paragraph.text as NSString
            for match in acronym.matches(in: paragraph.text, range: NSRange(location: 0, length: text.length)) {
                var name = text.substring(with: match.range)
                if name.hasSuffix("s"), name.dropLast().allSatisfy({ $0.isUppercase || $0.isNumber }) { name.removeLast() }
                guard name.count >= 2, name.count <= 8, !commonAcronyms.contains(name), seen.insert(name).inserted else { continue }
                // Defined if wrapped in parentheses, or followed by one.
                let before = match.range.location > 0 ? text.substring(with: NSRange(location: match.range.location - 1, length: 1)) : ""
                let afterStart = match.range.upperBound
                let after = afterStart < text.length ? text.substring(from: afterStart).trimmingCharacters(in: .whitespaces) : ""
                let defined = before == "(" || after.hasPrefix("(")
                if !defined, paragraph.kind != .heading {
                    findings.append(Finding(rule: .undefinedAcronym, line: paragraph.line(at: match.range.location), text: name))
                }
            }
        }
        return findings
    }

    private static func sectionScores(source: String, sentences: [ProseText.Sentence], findings: [Finding]) -> [(entry: DocumentOutline.Entry, words: Int, findings: Int)] {
        let headings = DocumentOutline.entries(in: source).filter { $0.endLine != nil }
        guard !headings.isEmpty else { return [] }
        /// The innermost section holding `line`.
        func section(_ line: Int) -> Int? {
            headings.indices.filter { headings[$0].line <= line && (headings[$0].endLine ?? 0) >= line }.last
        }
        var words = [Int](repeating: 0, count: headings.count)
        var counts = [Int](repeating: 0, count: headings.count)
        for sentence in sentences {
            if let index = section(sentence.line) { words[index] += ProseText.wordCount(sentence.text) }
        }
        for finding in findings {
            if let index = section(finding.line) { counts[index] += 1 }
        }
        return headings.indices.map { (headings[$0], words[$0], counts[$0]) }
    }

    private static func firstMatch(_ regex: NSRegularExpression, in text: String) -> NSRange? {
        regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))?.range
    }

    private static func clip(_ text: String) -> String {
        text.count > 90 ? String(text.prefix(90)) + "…" : text
    }

    // MARK: Rendering

    static let maxPerRule = 12

    static func render(_ report: Report, label: String, maxPerRule: Int = maxPerRule) -> String {
        let total = report.findings.count
        let per100 = report.words == 0 ? 0 : Double(total) * 100 / Double(report.words)
        var output = "[writing check of \(label) — \(report.words) words, \(report.sentences) sentences (mean \(String(format: "%.1f", report.meanSentence)), longest \(report.longestSentence) words), \(total) issue\(total == 1 ? "" : "s") = \(String(format: "%.1f", per100)) per 100 words]"
        if report.languages.count > 1 || report.nonEnglishParagraphs > 0 {
            let listed = report.languages.map { "\($0.name) (\($0.paragraphs) paragraph\($0.paragraphs == 1 ? "" : "s"))" }.joined(separator: ", ")
            output += "\nLanguages: \(listed)."
            if report.nonEnglishParagraphs > 0 {
                output += " STE grammar rules (contractions, modals, tenses, -ing clauses, passive voice, hype words, conditions, synonym rotation) apply to English only, so \(report.nonEnglishParagraphs) paragraph\(report.nonEnglishParagraphs == 1 ? " was" : "s were") checked for sentence length, dashes, semicolons, term spelling and acronyms."
            }
        }
        guard total > 0 else {
            return output + "\nNo mechanical rule broken. (Word choice and meaning are not checked.)"
        }
        for rule in Rule.allCases {
            let hits = report.findings.filter { $0.rule == rule }
            guard !hits.isEmpty else { continue }
            output += "\n\n\(rule.title) (\(hits.count)) — \(rule.fix)"
            for hit in hits.prefix(maxPerRule) {
                output += "\n  line \(hit.line): \(hit.text)"
                if let detail = hit.detail { output += " — \(detail)" }
            }
            if hits.count > maxPerRule { output += "\n  … \(hits.count - maxPerRule) more" }
        }
        let worst = report.sections
            .filter { $0.words >= 30 && $0.findings > 0 }
            .map { ($0.entry, Double($0.findings) * 100 / Double($0.words)) }
            .sorted { $0.1 > $1.1 }
            .prefix(5)
        if !worst.isEmpty {
            output += "\n\nSections with the most issues (per 100 words) — fix these first, e.g. read_file with section: \"\(worst.first!.0.text)\":"
            for (entry, score) in worst {
                output += "\n  \(String(format: "%.1f", score)) — \(entry.line)-\(entry.endLine ?? entry.line): \(entry.text)"
            }
        }
        output += "\n\nMechanical checks only (patterns and on-device word tagging): they can't judge word choice or meaning, and a few hits may be fine in context."
        return output
    }
}
