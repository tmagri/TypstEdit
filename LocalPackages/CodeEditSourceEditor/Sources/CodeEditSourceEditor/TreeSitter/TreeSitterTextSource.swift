//
//  TreeSitterTextSource.swift
//  CodeEditSourceEditor
//
//  Thread-safe text access for tree-sitter.
//

import AppKit
import CodeEditTextView

/// Gives tree-sitter access to the document's text from any thread.
///
/// `NSTextStorage` may only be touched on the main thread, and tree-sitter needs the text while it parses and
/// while it evaluates query predicates. The original design satisfied that by running the work *on* the main
/// thread: every parse slice (`parserTimeout`, 50 ms) and every async highlight query ran inside
/// `DispatchQueue.main`, and every read hopped there. In a large document that is exactly the work that stalled
/// typing, even though it was nominally "asynchronous".
///
/// This class removes the dependency. A background operation calls ``withSnapshot(_:)``, which copies the text
/// once, on the main thread, into an immutable `[UInt16]`; every read the operation makes afterwards comes from
/// that copy and never touches the main thread again. Measured on a 1.66M-unit document the copy takes ~0.07 ms,
/// against the ~50 ms parse slices it replaces.
///
/// Reads made on the main thread (the synchronous path) still read the live text storage, and reads made on a
/// background thread with no snapshot installed fall back to a main-thread hop, so code that has not adopted
/// ``withSnapshot(_:)`` keeps working exactly as before.
///
/// ## Why the snapshot is thread-local
/// The executor lets several `access` operations run at once, so a single shared "current snapshot" slot would
/// let one operation clear or replace another's. Each operation instead installs its own snapshot in its thread's
/// dictionary for the duration of its (synchronous) body, which is also the only place tree-sitter calls back
/// into the reader from.
final class TreeSitterTextSource: @unchecked Sendable {
    /// Documents above this many UTF-16 units are not snapshotted: copying them on every operation would no
    /// longer be negligible, so they keep the main-thread read path.
    static let maxSnapshotLength = 32_000_000

    /// Immutable copy of the text, owned by one operation.
    private final class Snapshot {
        let owner: ObjectIdentifier
        let units: [UInt16]
        init(owner: ObjectIdentifier, units: [UInt16]) {
            self.owner = owner
            self.units = units
        }
    }

    private static let threadKey = "CodeEditSourceEditor.TreeSitterTextSource.snapshot"

    /// Only dereferenced on the main thread.
    private weak var textView: TextView?

    /// How many times a background read had to hop to the main thread because no snapshot was installed.
    /// Zero for any operation that went through ``withSnapshot(_:)``; tests assert exactly that.
    private let fallbackHops = Atomic<Int>(0)
    var mainThreadFallbackCount: Int { fallbackHops.value() }

    init(textView: TextView) {
        self.textView = textView
    }

    // MARK: - Snapshot lifetime

    /// Runs `body` with a snapshot of the text installed for the current thread.
    ///
    /// On the main thread this is a no-op: reads there use the live text storage, which is always current.
    /// Otherwise the text is copied on the main thread (one hop) and installed until `body` returns.
    func withSnapshot<T>(_ body: () -> T) -> T {
        if Thread.isMainThread { return body() }

        let units: [UInt16]? = DispatchQueue.main.asyncAndWait { [weak self] in
            self?.copyText()
        }
        guard let units else { return body() }

        let thread = Thread.current.threadDictionary
        let previous = thread[Self.threadKey]
        thread[Self.threadKey] = Snapshot(owner: ObjectIdentifier(self), units: units)
        defer {
            if let previous {
                thread[Self.threadKey] = previous
            } else {
                thread.removeObject(forKey: Self.threadKey)
            }
        }
        return body()
    }

    /// Copies the text. Main thread only.
    private func copyText() -> [UInt16]? {
        guard let storage = textView?.textStorage else { return nil }
        let string = storage.mutableString as NSString
        let length = string.length
        guard length <= Self.maxSnapshotLength else { return nil }
        return [UInt16](unsafeUninitializedCapacity: length) { buffer, count in
            if let base = buffer.baseAddress, length > 0 {
                string.getCharacters(base, range: NSRange(location: 0, length: length))
            }
            count = length
        }
    }

    private var currentSnapshot: Snapshot? {
        guard let snapshot = Thread.current.threadDictionary[Self.threadKey] as? Snapshot,
              snapshot.owner == ObjectIdentifier(self) else { return nil }
        return snapshot
    }

    // MARK: - Reading

    /// The next chunk of UTF-16 text for tree-sitter's `readBlock`, starting at `byteOffset`.
    ///
    /// Returns an empty `Data` at the end of the document (tree-sitter's end-of-input signal) and `nil` for an
    /// offset past it. A chunk never ends between the two halves of a surrogate pair: tree-sitter decodes each
    /// chunk on its own, so a split pair would be read as two invalid characters.
    func chunk(atByteOffset byteOffset: Int, maxLength: Int) -> Data? {
        let location = byteOffset / 2
        guard location >= 0 else { return nil }

        if Thread.isMainThread {
            guard let storage = textView?.textStorage else { return nil }
            let string = storage.mutableString as NSString
            return Self.makeChunk(location: location, maxLength: maxLength, totalLength: string.length) { range, out in
                string.getCharacters(out, range: range)
            }
        }

        if let snapshot = currentSnapshot {
            return snapshot.units.withUnsafeBufferPointer { units in
                Self.makeChunk(location: location, maxLength: maxLength, totalLength: units.count) { range, out in
                    out.update(from: units.baseAddress! + range.location, count: range.length)
                }
            }
        }

        // No snapshot installed: read the live text on the main thread, as before.
        fallbackHops.mutate { $0 += 1 }
        return DispatchQueue.main.asyncAndWait { [weak self] in
            self?.chunk(atByteOffset: byteOffset, maxLength: maxLength)
        }
    }

    /// The text in `range`, for query predicates. `nil` if the range is outside the document.
    func string(in range: NSRange) -> String? {
        guard range.location >= 0, range.length >= 0 else { return nil }

        if Thread.isMainThread {
            guard let storage = textView?.textStorage else { return nil }
            let string = storage.mutableString as NSString
            guard range.location + range.length <= string.length else { return nil }
            return string.substring(with: range)
        }

        if let snapshot = currentSnapshot {
            guard range.location + range.length <= snapshot.units.count else { return nil }
            return String(
                decoding: snapshot.units[range.location..<(range.location + range.length)],
                as: UTF16.self
            )
        }

        fallbackHops.mutate { $0 += 1 }
        return DispatchQueue.main.asyncAndWait { [weak self] in
            self?.string(in: range)
        }
    }

    // MARK: - Chunking

    /// Builds one chunk. Factored out so the main-thread and snapshot readers share the exact same boundary
    /// rules.
    static func makeChunk(
        location: Int,
        maxLength: Int,
        totalLength: Int,
        copy: (_ range: NSRange, _ out: UnsafeMutablePointer<UInt16>) -> Void
    ) -> Data? {
        guard location <= totalLength else { return nil }
        var length = min(maxLength, totalLength - location)
        if length == 0 { return Data() }

        var buffer = [UInt16](repeating: 0, count: length)
        buffer.withUnsafeMutableBufferPointer { out in
            copy(NSRange(location: location, length: length), out.baseAddress!)
        }

        // Do not end a chunk on a lead surrogate. Never shorten a chunk to nothing: an empty chunk means
        // end-of-input to tree-sitter.
        if length > 1,
           location + length < totalLength,
           UTF16.isLeadSurrogate(buffer[length - 1]) {
            length -= 1
        }

        return buffer.withUnsafeBufferPointer { Data(buffer: UnsafeBufferPointer(rebasing: $0[0..<length])) }
    }
}
