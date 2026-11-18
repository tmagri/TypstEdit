import Foundation

/// Heuristic detection and prompt text for AI Chat's "auto-proceed" option:
/// when a finished reply says, in so many words, that work is still left, the
/// chat can start the next step by itself after a short countdown instead of
/// waiting for the user to type "continue".
///
/// The check deliberately looks only at the end of a reply (a next-steps list
/// is how a reply ends) and only at headings or plain statements of unfinished
/// work — ordinary prose that merely mentions "next steps" must not keep a
/// conversation running.
enum AIChatAutoProceed {
    /// What prompted a continuation.
    enum Trigger: Equatable {
        /// The reply named outstanding work ("Next steps", "Still to do", …).
        case unfinished
        /// The turn ended in an error. Only used when the user opted into
        /// continuing after failures.
        case failure(String)
    }

    /// How much of the reply's tail is inspected.
    static let inspectionCharacterLimit = 4_000

    /// Heading texts that name remaining work. Matched on a normalized line —
    /// markdown markers, bullets and list numbers stripped — either exactly or
    /// followed by a colon/dash ("Next steps: run the build").
    static let unfinishedHeadings: [String] = [
        "next steps", "next step", "next actions", "next action",
        "remaining work", "remaining steps", "remaining tasks",
        "remaining items", "remaining",
        "still to do", "still to be done", "left to do",
        "what's left", "whats left", "what is still left", "what's still left",
        "what remains", "to-do", "todo",
        "follow-up steps", "follow up steps", "follow-up work",
        "outstanding work", "unfinished work", "incomplete work",
        "not yet done", "not done yet",
    ]

    /// First-person or plain statements that work is not finished. Kept to
    /// phrases that assert unfinished work (not offers such as "let me know if
    /// you'd like me to…", which end almost every reply).
    static let unfinishedPhrases: [String] = [
        "i haven't finished", "i have not finished",
        "i didn't finish", "i did not finish",
        "i couldn't finish", "i could not finish",
        "i wasn't able to finish", "i was not able to finish",
        "i haven't been able to", "i did not get to", "i didn't get to",
        "i still need to", "i still have to",
        "still needs to be", "still need to be", "still remains to be",
        "remains to be done", "remains to be implemented", "remains to be written",
        "is not yet implemented", "are not yet implemented", "not yet implemented",
        "not yet complete", "not yet finished",
        "left to do", "left to finish", "left to implement",
        "we still need to", "we still have to",
        "there's still", "there is still",
        "the remaining work", "the remaining steps", "the remaining tasks",
        "next, i'll", "next i'll", "next i will",
        "i will now continue", "i'll continue with",
        "to be continued",
        "partially complete", "partially done",
    ]

    /// Hand-off phrases. A reply that ends "…next step when you're ready" or
    /// "let me know when you're ready and I'll continue" is explicitly holding
    /// work back for a go-ahead, so it counts as unfinished: Auto-proceed is
    /// exactly the user saying "go ahead without asking me".
    static let readyPhrases: [String] = [
        "when you're ready", "when you are ready", "whenever you're ready",
        "whenever you are ready", "when ready",
        "once you're ready", "once you are ready",
        "when you're set", "when you are set",
        "ready when you are",
        "say the word", "just say go", "say go",
        "next step when", "continue when", "proceed when",
        "let me know when you're ready", "let me know when you are ready",
        "tell me when you're ready", "tell me when you are ready",
        "happy to continue", "ready to continue", "ready for the next",
        "i can continue", "shall i continue", "should i continue",
        "want me to continue", "ready to proceed",
        "awaiting your go-ahead", "awaiting your approval to continue",
        "on your go-ahead", "on your signal",
    ]

    /// Whether a finished reply implies that more work remains. Empty text is
    /// never unfinished (an empty reply has its own retry path).
    static func looksUnfinished(_ reply: String) -> Bool {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let tail = trimmed.count > inspectionCharacterLimit
            ? String(trimmed.suffix(inspectionCharacterLimit))
            : trimmed
        if tail.components(separatedBy: .newlines).contains(where: isUnfinishedHeadingLine) {
            return true
        }
        let lower = tail.lowercased()
        return (unfinishedPhrases + readyPhrases).contains { lower.contains($0) }
    }

    /// The longest wait Auto-proceed will park for a provider's usage limit.
    /// Long enough to honour the five-hour window these messages describe
    /// (z.ai's GLM Coding Plan is the shape this parses), short enough that a
    /// chat is never left sleeping through a weekend. A reset further out than
    /// this is not worth waiting out unattended, so the caller falls back to
    /// the ordinary countdown and its round cap — which surfaces the "stopped"
    /// card instead of parking silently for hours on end.
    static let maxUsageLimitWait: TimeInterval = 6 * 60 * 60

    /// Floor for a honoured reset. A timestamp that has already passed, or
    /// lands within this second, is not a usable wait: returning it would make
    /// the countdown zero and re-send the request immediately into the same
    /// limit, burning auto-proceed rounds in a tight loop.
    static let minUsageLimitWait: TimeInterval = 1

    /// A provider's reset timestamp, with or without a zone, and with seconds,
    /// minutes or fractional seconds. `T` or a space may separate the date, and
    /// `Z`, `UTC`, `GMT`, `GMT+8` or `+08:00` may follow the time.
    private static let usageLimitTimestampPattern =
        #"\d{4}-\d{2}-\d{2}[ Tt]\d{2}:\d{2}(?::\d{2})?(?:\.\d+)?(?:\s*(?:[Zz]|UTC|GMT)(?:\s*[+-]\d{1,2}(?::?\d{2})?)?|\s*[+-]\d{1,2}(?::?\d{2})?)?"#

    /// The phrases providers use to introduce a reset. `reset at` covers
    /// z.ai's plan limits, `resets at` its extra-usage codes, and
    /// `regain access on` Anthropic's monthly spend cap.
    private static let usageLimitResetTriggers = [
        #"\bresets?\s+at\s+("# + usageLimitTimestampPattern + ")",
        #"\bregain\s+access\s+on\s+("# + usageLimitTimestampPattern + ")",
    ]

    /// Delay a failed API request until a reported usage-limit reset. Messages
    /// without a parseable reset time keep using the normal Auto-proceed delay.
    static func usageLimitRetryDelay(
        in failure: String,
        timeZone: TimeZone = .current,
        now: Date = Date()
    ) -> TimeInterval? {
        guard failure.range(of: "API Error (429)", options: .caseInsensitive) != nil,
              let timestamp = usageLimitResetTimestamp(in: failure),
              let resetDate = parseUsageLimitReset(timestamp, timeZone: timeZone) else { return nil }
        let delay = resetDate.timeIntervalSince(now)
        // Also the guard against the two ways this can go wrong quietly: a
        // timestamp already in the past (clock skew, or the wrong Server Time
        // Zone making an 8-hour wait look long gone) must not be clamped to
        // zero, and a weekly reset must not park the chat for days.
        guard delay >= minUsageLimitWait, delay <= maxUsageLimitWait else { return nil }
        return delay
    }

    /// The reset timestamp a 429 message names, as written, for
    /// `parseUsageLimitReset` to interpret.
    static func usageLimitResetTimestamp(in failure: String) -> String? {
        // Anthropic writes "regain access on 2026-09-01 at 00:00 UTC", with the
        // date and time split by the same word that introduces them. Join the
        // two first, so one timestamp pattern serves every phrasing.
        let text = joiningDateAndTime(in: failure)
        for trigger in usageLimitResetTriggers {
            guard let regex = try? NSRegularExpression(pattern: trigger, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { continue }
            return String(text[range]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Turns `2026-09-01 at 00:00` into `2026-09-01 00:00`.
    private static func joiningDateAndTime(in text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"(\d{4}-\d{2}-\d{2})\s+at\s+(?=\d)"#,
            options: [.caseInsensitive]
        ) else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: "$1 "
        )
    }

    /// Parses a reset timestamp. A zone on the timestamp always wins; only a
    /// timestamp without one is read in `timeZone` (the model's Server Time
    /// Zone). Splitting the zone off first is what makes `UTC` and `GMT` work:
    /// the previous implementation ran a space-to-`T` substitution before
    /// stripping the suffix, producing `2026-11-18T22:00:47TZ`, which never
    /// parsed.
    static func parseUsageLimitReset(_ raw: String, timeZone: TimeZone) -> Date? {
        let (body, zone) = splitZone(from: raw)
        let stamp = normalizedStamp(body)
        guard stamp.count >= 16 else { return nil }

        guard let zone else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = stamp.contains(".")
                ? "yyyy-MM-dd'T'HH:mm:ss.SSS"
                : "yyyy-MM-dd'T'HH:mm:ss"
            return formatter.date(from: stamp)
        }

        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: stamp + zone) { return date }
        // `ISO8601DateFormatter` only accepts fractional seconds when told to,
        // so a `.123Z` timestamp needs a second pass rather than being dropped.
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: stamp + zone)
    }

    /// `2026-11-18 22:00:47` → `2026-11-18T22:00:47`, with `HH:mm` widened to
    /// `HH:mm:ss` so one formatter handles both.
    private static func normalizedStamp(_ body: String) -> String {
        var stamp = body.trimmingCharacters(in: .whitespaces)
        if let regex = try? NSRegularExpression(
            pattern: #"^(\d{4}-\d{2}-\d{2})[ Tt](\d{2}:\d{2}(?::\d{2})?(?:\.\d+)?)"#,
            options: []
        ) {
            stamp = regex.stringByReplacingMatches(
                in: stamp,
                range: NSRange(stamp.startIndex..., in: stamp),
                withTemplate: "$1T$2"
            )
        }
        if stamp.count == 16 { stamp += ":00" }
        return stamp
    }

    /// Splits `2026-11-18 22:00:47 GMT+8` into its date/time body and a zone
    /// `ISO8601DateFormatter` accepts (`+08:00`). A bare `UTC`/`GMT` means
    /// offset zero.
    private static func splitZone(from raw: String) -> (body: String, zone: String?) {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard let regex = try? NSRegularExpression(
            pattern: #"(?i)\s*(?:(z|utc|gmt)(?:\s*([+-]\d{1,2})(?::?(\d{2}))?)?|([+-]\d{1,2}):?(\d{2}))$"#,
            options: []
        ),
        let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
        let full = Range(match.range(at: 0), in: text) else { return (text, nil) }

        let body = String(text[text.startIndex..<full.lowerBound])
        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
        if let word = group(1) {
            if word.caseInsensitiveCompare("Z") == .orderedSame { return (body, "Z") }
            guard let hours = group(2) else { return (body, "Z") }
            return (body, normalizedOffset(hours: hours, minutes: group(3)))
        }
        guard let hours = group(4) else { return (body, nil) }
        return (body, normalizedOffset(hours: hours, minutes: group(5)))
    }

    /// `+08:00`, `-0500` → `+08:00`, `-05:00`.
    private static func normalizedOffset(hours: String, minutes: String?) -> String {
        let sign = hours.hasPrefix("-") ? "-" : "+"
        var digits = hours
        if digits.hasPrefix("+") || digits.hasPrefix("-") { digits.removeFirst() }
        let hourText = String(repeating: "0", count: max(0, 2 - digits.count)) + digits
        let minuteDigits = minutes ?? ""
        let minuteText = String(repeating: "0", count: max(0, 2 - minuteDigits.count)) + minuteDigits
        return "\(sign)\(hourText):\(minuteText)"
    }

    private static func isUnfinishedHeadingLine(_ rawLine: String) -> Bool {
        let line = normalizedHeadingLine(rawLine)
        guard !line.isEmpty else { return false }
        for heading in unfinishedHeadings {
            if line == heading { return true }
            // A single word like "todo" or "remaining" must stand on its own;
            // a longer heading may introduce the list ("Next steps: …").
            guard heading != "todo", heading != "to-do", heading != "remaining" else { continue }
            guard line.hasPrefix(heading) else { continue }
            if let separator = line.dropFirst(heading.count).first,
               separator == ":" || separator == "—" || separator == "-" {
                return true
            }
        }
        return false
    }

    /// Strips the markdown decoration a heading or list item can carry, so
    /// `### Next steps`, `- **Next steps:**` and `2. Next steps` all reduce to
    /// the same text.
    private static func normalizedHeadingLine(_ raw: String) -> String {
        var line = raw.trimmingCharacters(in: .whitespaces)
        while line.hasPrefix("#") { line.removeFirst() }
        line = line.trimmingCharacters(in: .whitespaces)
        if let first = line.first, "-*•>+".contains(first) {
            line.removeFirst()
            line = line.trimmingCharacters(in: .whitespaces)
        }
        if let dot = line.firstIndex(of: ".") {
            let prefix = line[..<dot]
            if !prefix.isEmpty, prefix.allSatisfy({ $0.isNumber }) {
                line = String(line[line.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        while line.hasPrefix("*") { line.removeFirst() }
        while line.hasSuffix("*") { line.removeLast() }
        line = line.trimmingCharacters(in: .whitespaces)
        while let last = line.last, last == ":" || last == "—" || last == "-" {
            line.removeLast()
            line = line.trimmingCharacters(in: .whitespaces)
        }
        return line.lowercased()
    }

    /// The user-role message injected to keep the run going. It is explicit
    /// that the continuation is automatic, so the transcript and the model
    /// both know why another exchange appeared without the user typing.
    static func continuationText(trigger: Trigger, round: Int, maxRounds: Int) -> String {
        let progress = maxRounds > 0 ? "round \(round) of \(maxRounds)" : "round \(round)"
        switch trigger {
        case .unfinished:
            return """
            [Auto-proceed — \(progress)]
            Your previous reply said work was still outstanding. Continue now and finish it: pick up exactly where you stopped, use your tools, and keep any plan current. Do not ask for confirmation and do not repeat work that is already done. If the task is in fact complete, say so briefly and stop.
            """
        case .failure(let message):
            let clipped = message.count > 500 ? String(message.prefix(500)) + "…" : message
            return """
            [Auto-proceed after a failed attempt — \(progress)]
            The previous attempt ended with this error: \(clipped)

            Try again from where it stopped. If the same step failed twice, take a different approach instead of repeating it. Do not ask for confirmation unless you are truly blocked. If nothing more can be done, say briefly why and stop.
            """
        }
    }
}

/// The live countdown shown while AI Chat is about to continue on its own.
struct AutoProceedState: Equatable {
    let trigger: AIChatAutoProceed.Trigger
    let totalSeconds: Int
    var remainingSeconds: Int
}

extension AIChatAutoProceed.Trigger {
    /// True for the error-driven continuation, which gets different wording.
    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}
