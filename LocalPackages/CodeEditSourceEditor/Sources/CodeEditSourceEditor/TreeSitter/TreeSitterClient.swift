//
//  TreeSitterClient.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 9/12/22.
//

import Foundation
import CodeEditTextView
import CodeEditLanguages
import SwiftTreeSitter
import OSLog

/// # TreeSitterClient
///
/// ``TreeSitterClient`` is an class that manages a tree-sitter syntax tree and provides an API for notifying that
/// tree of edits and querying the tree. This type also conforms to ``HighlightProviding`` to provide syntax
/// highlighting.
///
/// The APIs this object provides can perform either asynchronously or synchronously. All calls to this object must
/// first be dispatched from the main queue to ensure serial access to internal properties. Any synchronous methods
/// can throw an ``TreeSitterClientExecutor/Error/syncUnavailable`` error if an asynchronous or synchronous call is
/// already being made on the object. In those cases it is up to the caller to decide whether or not to retry
/// asynchronously.
///
/// The only exception to the above rule is the ``HighlightProviding`` conformance methods. The methods for that
/// implementation may return synchronously or asynchronously depending on a variety of factors such as document
/// length, edit length, highlight length and if the object is available for a synchronous call.
public final class TreeSitterClient: HighlightProviding {
    static let logger: Logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "", category: "TreeSitterClient")

    enum TreeSitterClientError: Error {
        case invalidEdit
    }

    // MARK: - Properties

    /// A callback to use to efficiently fetch portions of text.
    var readBlock: Parser.ReadBlock?

    /// A callback used to fetch text for queries.
    var readCallback: SwiftTreeSitter.Predicate.TextProvider?

    /// Moving average of how long recent edits took to apply, in seconds. See ``Constants/maxSyncEditDuration``.
    private let recentEditCost = Atomic<TimeInterval>(0)

    /// Folds one measured edit into ``recentEditCost``.
    private func recordEditCost(_ duration: Duration) {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        recentEditCost.mutate { $0 = $0 == 0 ? seconds : ($0 * 0.5 + seconds * 0.5) }
    }

    private func seedEditCost(_ duration: Duration) {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        recentEditCost.mutate { $0 = seconds }
    }

    /// Thread-safe access to the document text, so background operations never need the main thread.
    private var textSource: TreeSitterTextSource?

    /// The internal tree-sitter layer tree object.
    var state: TreeSitterState?

    package var executor: TreeSitterExecutor = .init()

    /// The end point of the previous edit.
    private var oldEndPoint: Point?

    package var pendingEdits: Atomic<[InputEdit]> = Atomic([])

    /// Optional flag to force every operation to be done on the caller's thread.
    package var forceSyncOperation: Bool = false

    public init() { }

    // MARK: - Constants

    public enum Constants {
        /// The maximum amount of limits a cursor can match during a query.
        ///
        /// Used to ensure performance in large files, even though we generally limit the query to the visible range.
        /// Neovim encountered this issue and uses 64 for their limit. Helix uses 256 due to issues with some
        /// languages when using 64.
        /// See: [github.com/neovim](https://github.com/neovim/neovim/issues/14897)
        /// And: [github.com/helix-editor](https://github.com/helix-editor/helix/pull/4830)
        public static var matchLimit = 256

        /// The timeout for parsers to re-check if a task is canceled. This constant represents the period between
        /// checks and is directly related to editor responsiveness.
        public static var parserTimeout: TimeInterval = 0.05

        /// The maximum length of an edit before it must be processed asynchronously
        public static var maxSyncEditLength: Int = 1024

        /// The maximum length a document can be before all queries and edits must be processed asynchronously.
        public static var maxSyncContentLength: Int = 1_000_000

        /// How long an edit may take, on average, and still be processed synchronously on the main thread.
        ///
        /// A fixed document length cannot predict this: the cost of an incremental edit depends on the grammar
        /// as much as on the size (measured at 0.7 MB: ~15 ms for real Typst, ~51 ms for Markdown and `.note`).
        /// The client therefore times its own edits, and once they are slower than this it moves them to the
        /// background executor. 12 ms leaves headroom inside a 16.7 ms frame for the rest of a keystroke.
        public static var maxSyncEditDuration: TimeInterval = 0.012

        /// The maximum length a query can be before it must be performed asynchronously.
        public static var maxSyncQueryLength: Int = 4096

        /// The number of characters to read in a read block.
        ///
        /// This has diminishing returns on the number of times the read block is called as this number gets large.
        public static let charsToReadInBlock: Int = 4096

        /// The duration before a long parse notification is sent.
        public static var longParseTimeout: Duration = .seconds(0.5)

        /// The notification name sent when a long parse is detected.
        public static let longParse: Notification.Name = .init("CodeEditSourceEditor.longParseNotification")

        /// The notification name sent when a long parse is finished.
        public static let longParseFinished: Notification.Name = .init(
            "CodeEditSourceEditor.longParseFinishedNotification"
        )

        /// The duration tasks sleep before checking if they're runnable.
        ///
        /// Lower than 1ms starts causing bad lock contention, much higher reduces responsiveness with diminishing
        /// returns on CPU efficiency.
        public static let taskSleepDuration: Duration = .milliseconds(10)
    }

    // MARK: - HighlightProviding

    /// Set up the client with a text view and language.
    /// - Parameters:
    ///   - textView: The text view to use as a data source.
    ///               A weak reference will be kept for the lifetime of this object.
    ///   - codeLanguage: The language to use for parsing.
    public func setUp(textView: TextView, codeLanguage: CodeLanguage) {
        Self.logger.debug("TreeSitterClient setting up with language: \(codeLanguage.id.rawValue, privacy: .public)")

        let source = TreeSitterTextSource(textView: textView)
        self.textSource = source
        recentEditCost.mutate { $0 = 0 }
        let readBlock = textView.createReadBlock(source: source)
        let readCallback = textView.createReadCallback(source: source)
        self.readBlock = readBlock
        self.readCallback = readCallback

        let operation = { [weak self] in
            let start = ContinuousClock.now
            let state = TreeSitterState(
                codeLanguage: codeLanguage,
                readCallback: readCallback,
                readBlock: readBlock
            )
            self?.state = state
            // Seed the edit-cost estimate with the full parse. Without a seed the first edit after opening a
            // large document has nothing to go on and runs synchronously, so it alone pays the hitch the
            // adaptive threshold exists to avoid. For a grammar whose incremental edits are far cheaper than
            // its full parse this over-estimates, but the moving average decays within a few edits, which at
            // worst run in the background a little earlier than they needed to.
            if !Task.isCancelled { self?.seedEditCost(start.duration(to: .now)) }
        }

        executor.cancelAll(below: .all)
        if forceSyncOperation {
            executor.execSync(operation)
        } else {
            executor.execAsync(
                priority: .reset,
                operation: { source.withSnapshot(operation) },
                onCancel: {}
            )
        }
    }

    // MARK: - HighlightProviding

    /// Notifies the highlighter of an edit and in exchange gets a set of indices that need to be re-highlighted.
    /// The returned `IndexSet` should include all indexes that need to be highlighted, including any inserted text.
    /// - Parameters:
    ///   - textView: The text view to use.
    ///   - range: The range of the edit.
    ///   - delta: The length of the edit, can be negative for deletions.
    ///   - completion: The function to call with an `IndexSet` containing all Indices to invalidate.
    public func applyEdit(
        textView: TextView,
        range: NSRange,
        delta: Int,
        completion: @escaping @MainActor (Result<IndexSet, Error>) -> Void
    ) {
        let oldEndPoint: Point = self.oldEndPoint ?? textView.pointForLocation(range.max) ?? .zero
        self.oldEndPoint = nil
        guard let edit = InputEdit(range: range, delta: delta, oldEndPoint: oldEndPoint, textView: textView) else {
            completion(.failure(TreeSitterClientError.invalidEdit))
            return
        }

        let operation = { [weak self] () -> IndexSet in
            guard let self else { return IndexSet() }
            let start = ContinuousClock.now
            let invalidated = self.applyEdit(edit: edit)
            // A cancelled operation stops early, so its duration says nothing about what an edit costs.
            if !Task.isCancelled { self.recordEditCost(start.duration(to: .now)) }
            return invalidated
        }

        // Captured here, on the calling (main) thread: `setUp` may replace `textSource` while the background
        // operation below is still running, and a property read from another thread would race with that.
        let source = textSource

        let longEdit = range.length > Constants.maxSyncEditLength
        let longDocument = textView.documentRange.length > Constants.maxSyncContentLength
        let slowEdits = recentEditCost.value() > Constants.maxSyncEditDuration
        let execAsync = longEdit || longDocument || slowEdits

        if !execAsync || forceSyncOperation {
            let result = executor.execSync(operation)
            if case .success(let invalidatedRanges) = result {
                DispatchQueue.dispatchMainIfNot { completion(.success(invalidatedRanges)) }
                return
            }
        }

        if !forceSyncOperation {
            executor.cancelAll(below: .reset) // Cancel all edits, add it to the pending edit queue
            executor.execAsync(
                priority: .edit,
                operation: {
                    // The parse runs here, off the main thread, against a snapshot of the text. Only the result
                    // is handed back to the main thread: the completion belongs to the main-actor highlighter.
                    let invalidated = source?.withSnapshot(operation) ?? operation()
                    DispatchQueue.dispatchMainIfNot { completion(.success(invalidated)) }
                },
                onCancel: { [weak self] in
                    self?.pendingEdits.mutate { edits in
                        edits.append(edit)
                    }
                    DispatchQueue.dispatchMainIfNot {
                        completion(.failure(HighlightProvidingError.operationCancelled))
                    }
                }
            )
        }
    }

    /// Called before an edit is sent. We use this to set the ``oldEndPoint`` variable so tree-sitter knows where
    /// the document used to end.
    /// - Parameters:
    ///   - textView: The text view used.
    ///   - range: The range that will be edited.
    public func willApplyEdit(textView: TextView, range: NSRange) {
        oldEndPoint = textView.pointForLocation(range.max)
    }

    /// Initiates a highlight query.
    /// - Parameters:
    ///   - textView: The text view to use.
    ///   - range: The range to limit the highlights to.
    ///   - completion: Called when the query completes.
    public func queryHighlightsFor(
        textView: TextView,
        range: NSRange,
        completion: @escaping @MainActor (Result<[HighlightRange], Error>) -> Void
    ) {
        let operation = { [weak self] in
            return (self?.queryHighlightsForRange(range: range) ?? []).sorted { $0.range.location < $1.range.location }
        }

        let source = textSource   // captured on the calling thread; see `applyEdit`

        let longQuery = range.length > Constants.maxSyncQueryLength
        let longDocument = textView.documentRange.length > Constants.maxSyncContentLength
        let execAsync = longQuery || longDocument

        if !execAsync || forceSyncOperation {
            let result = executor.execSync(operation)
            if case .success(let highlights) = result {
                DispatchQueue.dispatchMainIfNot { completion(.success(highlights)) }
                return
            }
        }

        if !forceSyncOperation {
            executor.execAsync(
                priority: .access,
                operation: {
                    // Previously `operation()` itself ran inside `dispatchMainIfNot`, i.e. on the main thread,
                    // because the predicate text provider needed the text storage. It now reads a snapshot, so
                    // only the completion is delivered on the main thread.
                    let highlights = source?.withSnapshot(operation) ?? operation()
                    DispatchQueue.dispatchMainIfNot { completion(.success(highlights)) }
                },
                onCancel: {
                    DispatchQueue.dispatchMainIfNot {
                        completion(.failure(HighlightProvidingError.operationCancelled))
                    }
                }
            )
        }
    }
}
