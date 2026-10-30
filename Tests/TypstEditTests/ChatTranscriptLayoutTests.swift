import XCTest
import SwiftUI
import AppKit
@testable import TypstEdit

/// Hosts the real chat panel offscreen with a long, uneven transcript (the
/// shape that used to blank the view) and checks two things: the viewport
/// ends exactly on the bottom (no gap, no overscroll) while following, and a
/// streamed update stays cheap enough for a low-end Mac.
@MainActor
final class ChatTranscriptLayoutTests: XCTestCase {

    private static var controllerKey = 0

    private var savedChatEnabled: Any?

    override func setUp() async throws {
        savedChatEnabled = UserDefaults.standard.object(forKey: "aiChatEnabled")
        UserDefaults.standard.set(true, forKey: "aiChatEnabled")
    }

    override func tearDown() async throws {
        if let savedChatEnabled {
            UserDefaults.standard.set(savedChatEnabled, forKey: "aiChatEnabled")
        } else {
            UserDefaults.standard.removeObject(forKey: "aiChatEnabled")
        }
    }

    /// 300 messages of very different heights: short asks, tool calls with
    /// long outputs, markdown answers with code blocks.
    private func longTranscript() -> [ChatMessage] {
        var messages: [ChatMessage] = []
        for turn in 0..<60 {
            messages.append(ChatMessage(role: .user, text: "Step \(turn): check the spread widths and regenerate the outputs."))
            for call in 0..<3 {
                messages.append(ChatMessage(
                    role: .toolCall,
                    text: "",
                    toolName: "read_file",
                    toolArgumentsJSON: #"{"path":"agents/example_runner/generate_\#(turn)_\#(call).py"}"#,
                    toolStatus: .succeeded,
                    toolOutput: String(repeating: "line of tool output \(call)\n", count: 40)
                ))
            }
            let paragraphs = String(repeating: "The measured artboard grew by 3.2 mm on the hardcover variant. ", count: 1 + turn % 9)
            messages.append(ChatMessage(
                role: .assistant,
                text: "## Result \(turn)\n\n\(paragraphs)\n\n```python\nfor gang in gangs:\n    render(gang)\n```\n",
                reasoning: turn % 4 == 0 ? String(repeating: "thinking ", count: 200) : nil
            ))
        }
        return messages
    }

    private func host(_ chat: AIChatManager) -> (NSWindow, NSView) {
        // Hosted the way FractionalSplitView hosts the sidebar: a hosting
        // controller pinned inside a container with Auto Layout.
        let controller = NSHostingController(rootView: AIChatView(controller: EditorController(), chat: chat))
        controller.sizingOptions = [] // as FractionalSplitView sets for the sidebar
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView()
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        objc_setAssociatedObject(view, &Self.controllerKey, controller, .OBJC_ASSOCIATION_RETAIN)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 1200),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        // Created in code, so AppKit would otherwise release it on close on
        // top of ARC's release — a crash when the test tears down.
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return (window, view)
    }

    private func pump(_ seconds: TimeInterval, _ view: NSView) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            view.layoutSubtreeIfNeeded()
        }
    }

    /// The transcript is the tallest scroll view in the panel (the plan card
    /// and thinking box have their own, much shorter ones).
    private func transcriptScrollView(in view: NSView) -> NSScrollView? {
        var found: [NSScrollView] = []
        func walk(_ node: NSView) {
            if let scroll = node as? NSScrollView { found.append(scroll) }
            node.subviews.forEach(walk)
        }
        walk(view)
        return found.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }

    private func distanceToBottom(_ scroll: NSScrollView) -> CGFloat {
        let clip = scroll.contentView
        let maxOffset = max(0, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height)
        return maxOffset - clip.bounds.origin.y
    }

    func testFollowingLandsExactlyOnTheBottomOfALongTranscript() throws {
        let chat = AIChatManager(messages: longTranscript())
        let (window, view) = host(chat)
        defer { window.close() }
        pump(0.6, view)

        let scroll = try XCTUnwrap(transcriptScrollView(in: view))
        XCTAssertGreaterThan(scroll.documentView?.frame.height ?? 0, scroll.contentView.bounds.height * 2,
                             "the fixture must overflow the viewport to test anything")
        XCTAssertEqual(distanceToBottom(scroll), 0, accuracy: 1, "opened on a long chat: pinned to the bottom")

        // Stream for a while, then end the turn (the live row disappears and
        // the content shrinks — the old overscroll/blank-gap case).
        chat.isGenerating = true
        for index in 0..<40 {
            chat.appendLiveReasoning("token \(index) of the reasoning stream ")
            pump(0.02, view)
        }
        pump(0.5, view)
        XCTAssertEqual(distanceToBottom(scroll), 0, accuracy: 1, "still pinned while streaming")
        XCTAssertGreaterThanOrEqual(distanceToBottom(scroll), -1, "never parked past the content")

        chat.isGenerating = false
        pump(0.6, view)
        XCTAssertEqual(distanceToBottom(scroll), 0, accuracy: 1, "no gap left behind when the live row goes")
    }

    /// CPU the main thread spends on the panel while a reply streams into a
    /// long chat, as a fraction of wall time. Measured as thread CPU time,
    /// not wall time: the run loop sleeps between display ticks, and that
    /// idle wait is not load. Streams at 100 deltas a second (a fast model)
    /// through the real throttle for two seconds.
    private enum Load { case idle, generatingQuietly, streaming, streamingUnthrottled }

    private func mainThreadLoad(_ load: Load) -> Double {
        let chat = AIChatManager(messages: longTranscript())
        let (window, view) = host(chat)
        defer { window.close() }
        chat.isGenerating = load != .idle
        pump(0.6, view)

        // Deltas come from a run-loop timer, so between them the run loop
        // genuinely sleeps — the measurement must not spin.
        var index = 0
        let timer = Timer(timeInterval: 0.01, repeats: true) { _ in
            MainActor.assumeIsolated {
                switch load {
                case .idle, .generatingQuietly:
                    return
                case .streaming:
                    chat.appendLiveReasoning("token \(index) of a fast reasoning stream ")
                case .streamingUnthrottled:
                    chat.appendLiveReasoning("token \(index) of a fast reasoning stream ")
                    chat.flushLiveReasoning()
                }
                index += 1
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }

        let wallStart = Date()
        let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        RunLoop.main.run(until: wallStart.addingTimeInterval(2))
        let cpu = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1e9
        return cpu / Date().timeIntervalSince(wallStart)
    }

    /// The slowest Macs the app supports (8 GB Intel laptops) are roughly
    /// three to four times slower than a current Apple-silicon machine on
    /// single-thread work. Streaming measures about 8% here, so about 25–35%
    /// there: typing and scrolling stay responsive. The old path (one update
    /// per token, hosting view re-deriving sizes) measured 96% here, which
    /// saturates even a fast Mac; the 15% bound catches a regression towards
    /// that with margin for a busy machine.
    func testStreamingStaysCheapOnALongTranscript() throws {
        let idle = mainThreadLoad(.idle)
        let quiet = mainThreadLoad(.generatingQuietly)
        let throttled = mainThreadLoad(.streaming)
        let unthrottled = mainThreadLoad(.streamingUnthrottled)
        NSLog("%@", "ChatTranscriptLayoutTests: main-thread load — idle \(Int(idle * 100))%, generating \(Int(quiet * 100))%, streaming \(Int(throttled * 100))%, per-delta \(Int(unthrottled * 100))%")
        XCTAssertLessThan(throttled, 0.15, "streaming into a long chat must leave the main thread mostly free")
        XCTAssertLessThan(throttled, unthrottled, "the throttle must actually reduce the work")
    }
}
