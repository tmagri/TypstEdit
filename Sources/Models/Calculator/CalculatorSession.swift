import Foundation
import Combine

/// The live state of one calculator session: the TI-89 style history, the
/// current modes, and the saved-file bookkeeping. Owned by
/// `EditorController` so it survives switching between the Files / AI Chat /
/// Calculator panels.
@MainActor
final class CalculatorSession: ObservableObject {

    // MARK: - Published state

    @Published var entries: [CalculatorEntry] = []
    @Published var angle: CASAngleMode = GeneralSettingsManager.shared.calcAngleMode
    @Published var exactMode: CASExactMode = GeneralSettingsManager.shared.calcExactMode
    @Published var displayDigits: Int = GeneralSettingsManager.shared.calcDisplayDigits
    @Published var busy = false
    @Published var documentURL: URL?
    @Published var hasUnsavedChanges = false
    /// Index of the history line currently highlighted with the arrow keys
    /// (TI-89 entry recall), from the end. `nil` when none is selected.
    @Published var recallIndex: Int?
    @Published var storedVariables: [CalculatorStoredVariable] = []
    @Published var lastStatus: String?

    /// The entry line contents — kept here (not in the view) so it survives
    /// panel switches, like the TI-89's entry line.
    @Published var entryLine: String = ""

    // MARK: - Derived

    var sessionName: String {
        documentURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    var statusText: String {
        var parts: [String] = []
        parts.append(angle.rawValue)
        parts.append(exactMode.rawValue.uppercased())
        if !entries.isEmpty {
            parts.append("\(entries.count)")
        }
        if let recallIndex, entries.count > recallIndex {
            parts.append("entry \(entries.count - recallIndex)/\(entries.count)")
        }
        return parts.joined(separator: "  ")
    }

    // MARK: - Evaluation

    /// Evaluates the entry line. `forceApprox` is the ⌥↩ (diamond-Enter)
    /// behaviour: evaluate this line as a decimal regardless of AUTO/EXACT.
    func submit(_ rawInput: String, forceApprox: Bool = false) async {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !busy else { return }

        do {
            var prepared = TISyntax.preprocess(trimmed)
            prepared = try TISyntax.substituteRecalls(in: prepared, history: entries)

            busy = true
            lastStatus = nil
            let approx = forceApprox || exactMode == .approx
            let result = await CASEngine.shared.eval(
                input: prepared,
                approx: approx,
                angle: angle,
                digits: displayDigits,
                timeout: GeneralSettingsManager.shared.calcTimeout)

            let entry = CalculatorEntry(
                input: trimmed,
                approx: approx,
                resultTypst: result.resultTypst,
                resultPlain: result.resultText,
                inputTypst: result.inputTypst,
                isError: !result.ok,
                errorMessage: result.errorMessage)

            entries.append(entry)
            hasUnsavedChanges = true
            recallIndex = nil
            trackStoredVariable(prepared: prepared, input: trimmed)
            busy = false
        } catch {
            busy = false
            entries.append(CalculatorEntry(
                input: trimmed,
                isError: true,
                errorMessage: error.localizedDescription))
            hasUnsavedChanges = true
        }
    }

    /// `5►a` style stores are tracked so saved sessions can restore them.
    private func trackStoredVariable(prepared: String, input: String) {
        guard let arrow = prepared.firstIndex(of: "►") else { return }
        let name = String(prepared[prepared.index(after: arrow)...])
            .trimmingCharacters(in: .whitespaces)
        let value = String(prepared[prepared.startIndex..<arrow])
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else { return }
        storedVariables.removeAll { $0.name == name }
        storedVariables.append(CalculatorStoredVariable(name: name, value: value))
    }

    func interrupt() {
        guard busy else { return }
        Task {
            await CASEngine.shared.interrupt()
        }
    }

    /// Moves the history highlight with ↑/↓. Returns the recalled text for
    /// the entry line (TI-89: ENTER on a selected entry copies it down).
    func moveRecall(_ direction: Int) -> String? {
        guard !entries.isEmpty else { return nil }
        let current = recallIndex ?? -1
        let next = min(max(current + (direction < 0 ? 1 : -1), -1), entries.count - 1)
        if next < 0 {
            recallIndex = nil
            return nil
        }
        recallIndex = next
        return entries[entries.count - 1 - next].input
    }

    func clearHistory() {
        entries.removeAll()
        recallIndex = nil
        hasUnsavedChanges = true
    }

    func deleteEntry(id: UUID) {
        entries.removeAll { $0.id == id }
        if let selected = recallIndex, selected >= entries.count {
            recallIndex = entries.isEmpty ? nil : entries.count - 1
        }
        hasUnsavedChanges = true
    }

    /// TI-89 Clean Up → delVar: forget one stored variable everywhere.
    func deleteVariable(name: String) {
        storedVariables.removeAll { $0.name == name }
        hasUnsavedChanges = true
        Task {
            _ = await CASEngine.shared.eval(
                input: "purge(\(name))",
                approx: false, angle: angle, digits: displayDigits, timeout: 5)
        }
    }

    // MARK: - New / save / open

    func newSession() {
        entries.removeAll()
        storedVariables.removeAll()
        entryLine = ""
        recallIndex = nil
        documentURL = nil
        hasUnsavedChanges = false
        lastStatus = nil
        Task {
            await CASEngine.shared.reset()
        }
    }

    func save(to url: URL) throws {
        let document = CalculatorDocument(
            angle: angle,
            exactMode: exactMode,
            displayDigits: displayDigits,
            variables: storedVariables,
            entries: entries)
        try CalculatorDocument.save(document, to: url)
        documentURL = url
        hasUnsavedChanges = false
        lastStatus = "Saved \(url.lastPathComponent)"
    }

    func save() {
        if let documentURL {
            try? save(to: documentURL)
        }
    }

    /// Loads a `.tcalc` file into this session and replays its stored
    /// variables through the engine in the background, so `ans`-style
    /// references and later entries keep working. An empty (just-created)
    /// or unreadable file starts a fresh session bound to that URL.
    func load(from url: URL) {
        let document: CalculatorDocument?
        if let raw = try? Data(contentsOf: url), !raw.isEmpty {
            document = try? CalculatorDocument.load(from: url)
        } else {
            document = CalculatorDocument()
        }
        guard let document else {
            lastStatus = "Could not read \(url.lastPathComponent)"
            return
        }
        entries = document.entries
        storedVariables = document.variables
        angle = document.angle
        exactMode = document.exactMode
        displayDigits = document.displayDigits
        entryLine = ""
        recallIndex = nil
        documentURL = url
        hasUnsavedChanges = false
        lastStatus = nil

        let variables = storedVariables
        let restoreAngle = angle
        let digits = displayDigits
        Task {
            await CASEngine.shared.reset()
            for variable in variables {
                _ = await CASEngine.shared.eval(
                    input: TISyntax.preprocess("\(variable.value)►\(variable.name)"),
                    approx: false,
                    angle: restoreAngle,
                    digits: digits,
                    timeout: 5)
            }
        }
    }

    // MARK: - Export

    func exportTypst() -> String {
        let document = CalculatorDocument(
            angle: angle,
            exactMode: exactMode,
            displayDigits: displayDigits,
            variables: storedVariables,
            entries: entries)
        return CalculatorExport.typst(sessionName: sessionName, document: document)
    }

    // MARK: - Insertion strings

    /// `$ … $` ready to drop into the editor at the cursor.
    nonisolated static func inlineEquation(_ math: String) -> String {
        "$\(math)$"
    }

    /// `$ … $` on its own line (display style when it stands alone in Typst).
    nonisolated static func blockEquation(_ math: String) -> String {
        "$ \(math) $"
    }

    /// `$ input = result $`.
    nonisolated static func inputEqualsResult(_ entry: CalculatorEntry) -> String {
        "$ \(entry.inputTypst) = \(entry.resultTypst) $"
    }
}
