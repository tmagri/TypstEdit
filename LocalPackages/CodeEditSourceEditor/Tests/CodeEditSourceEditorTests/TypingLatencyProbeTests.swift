import XCTest
import AppKit
import CodeEditTextView
import CodeEditLanguages
@testable import CodeEditSourceEditor

/// Opt-in benchmark: types into the real editor stack (text view, layout manager,
/// highlighter, tree-sitter) on a large document and reports main-thread latency.
/// It asserts nothing and is skipped unless `PROBE_DOC` points at a text file, so it
/// costs nothing in a normal test run.
///
/// Numbers are only meaningful from a release build:
///
///     PROBE_DOC=/path/to/big.note PROBE_LANG=note PROBE_KEYS=20 \
///       swift test -c release -Xswiftc -enable-testing --filter TypingLatencyProbeTests
///
/// `PROBE_LANG` is a `CodeLanguage.tsName` (note, markdown, typst, PlainText); omit it to
/// run all four. Run each configuration several times: when tree-sitter parses off the main
/// thread, the stall it causes depends on how quickly the background work gets to run.
@MainActor
final class TypingLatencyProbeTests: XCTestCase {
    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Process CPU time (user + system, all threads) in milliseconds.
    private func cpuMs() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func ms(_ t: timeval) -> Double { Double(t.tv_sec) * 1000 + Double(t.tv_usec) / 1000 }
        return ms(usage.ru_utime) + ms(usage.ru_stime)
    }

    /// Longest gap between 1 ms main-queue timer ticks while `body` pumps the run loop.
    private func measureStalls(during seconds: TimeInterval) -> (maxGapMs: Double, totalBusyMs: Double) {
        var last = DispatchTime.now().uptimeNanoseconds
        var maxGap: UInt64 = 0
        var busy: UInt64 = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 0.001, repeats: true) { _ in
            let now = DispatchTime.now().uptimeNanoseconds
            let gap = now - last
            if gap > 5_000_000 { busy += gap }   // anything over 5 ms counts as a stall
            maxGap = max(maxGap, gap)
            last = now
        }
        spin(seconds)
        timer.invalidate()
        return (Double(maxGap) / 1e6, Double(busy) / 1e6)
    }

    private func probe(_ label: String, language: CodeLanguage, text: String) {
        let controller = TextViewController(
            string: text,
            language: language,
            configuration: Mock.config(),
            cursorPositions: [],
            highlightProviders: [TreeSitterClient()]
        )
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        controller.view.layoutSubtreeIfNeeded()

        let openStart = DispatchTime.now().uptimeNanoseconds
        let open = measureStalls(during: 6.0)
        _ = openStart

        let textView = controller.textView!
        let mid = (textView.string as NSString).length / 2
        textView.selectionManager.setSelectedRange(NSRange(location: mid, length: 0))

        let cpuStart = cpuMs()
        let wallStart = DispatchTime.now().uptimeNanoseconds
        var syncMs: [Double] = []
        var worstStall = 0.0
        var totalStall = 0.0
        let keystrokes = Int(ProcessInfo.processInfo.environment["PROBE_KEYS"] ?? "20") ?? 20
        for i in 0..<keystrokes {
            let t0 = DispatchTime.now().uptimeNanoseconds
            textView.replaceCharacters(in: NSRange(location: mid + i, length: 0), with: "x")
            let t1 = DispatchTime.now().uptimeNanoseconds
            syncMs.append(Double(t1 - t0) / 1e6)
            // Type at ~7 chars/sec: lets async work interleave like real typing.
            let s = measureStalls(during: 0.15)
            worstStall = max(worstStall, s.maxGapMs)
            totalStall += s.totalBusyMs
        }
        let typingCPU = cpuMs() - cpuStart
        let typingWall = Double(DispatchTime.now().uptimeNanoseconds - wallStart) / 1e6
        let settle = measureStalls(during: 4.0)

        syncMs.sort()
        let median = syncMs[syncMs.count / 2]
        let p95 = syncMs[Int(Double(syncMs.count) * 0.95)]
        print(String(format: "PROBE %-34@ open-stall max %7.1f ms | keystroke sync median %6.2f p95 %6.2f ms | typing: worst main stall %7.1f ms, stalled-total %7.1f ms | settle max stall %6.1f ms | CPU while typing %5.0f%% of one core",
                     label as NSString, open.maxGapMs, median, p95, worstStall, totalStall, settle.maxGapMs, typingCPU / typingWall * 100))
    }

    func test_probe() throws {
        guard let path = ProcessInfo.processInfo.environment["PROBE_DOC"] else {
            throw XCTSkip("PROBE_DOC not set")
        }
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let only = ProcessInfo.processInfo.environment["PROBE_LANG"]
        let cases: [(String, CodeLanguage)] = [("note (hybrid markdown+typst)", .note),
                                               ("markdown", .markdown),
                                               ("typst (fallback grammar)", .typst),
                                               ("plain text (fallback)", .default)]
        for (label, language) in cases where only == nil || only == language.tsName {
            probe(label, language: language, text: text)
        }
    }
}
