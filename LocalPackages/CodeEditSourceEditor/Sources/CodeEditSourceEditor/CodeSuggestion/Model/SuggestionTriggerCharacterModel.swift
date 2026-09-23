import AppKit
import CodeEditTextView
import TextStory
import Combine

@MainActor
final class SuggestionTriggerCharacterModel {
    weak var controller: TextViewController?
    private var lastPosition: NSRange?
    
    // Add a Combine publisher/timer for debouncing keystrokes
    private var debounceTimer: AnyCancellable?
    let debounceInterval: TimeInterval = 0.25

    func textView(_ textView: TextView, didReplaceContentsIn range: NSRange, with string: String) {
        let mutation = TextMutation(
            string: string,
            range: range,
            limit: textView.textStorage.length
        )

        guard mutation.delta >= 0 else {
            lastPosition = nil
            debounceTimer?.cancel()
            return
        }

        lastPosition = NSRange(location: mutation.postApplyRange.max, length: 0)
        
        // Cancel any existing timer
        debounceTimer?.cancel()
        
        // Grab the controller and delegate
        guard let controller = controller, let completionDelegate = controller.completionDelegate else { return }
        
        // Check the delegate for the continuous completion setting
        guard completionDelegate.isContinuousCompletionEnabled else { return }
        
        // Only auto-trigger on actual text insertion, not pure cursor moves
        if !string.isEmpty {
            debounceTimer = Just(())
                .delay(for: .seconds(debounceInterval), scheduler: RunLoop.main)
                .sink { [weak self] _ in
                    self?.triggerAutoCompletion()
                }
        }
    }

    private func triggerAutoCompletion() {
        guard let controller, let completionDelegate = controller.completionDelegate,
              let position = controller.cursorPositions.first else {
            return
        }

        if SuggestionController.shared.isVisible {
            SuggestionController.shared.cursorsUpdated(
                textView: controller,
                delegate: completionDelegate,
                position: position
            )
        } else {
            SuggestionController.shared.showCompletions(
                textView: controller,
                delegate: completionDelegate,
                cursorPosition: position
            )
        }
    }

    func selectionUpdated(_ position: CursorPosition) {
        guard let controller, let completionDelegate = controller.completionDelegate else {
            return
        }

        if lastPosition != position.range {
            debounceTimer?.cancel() // Cancel typing debounces if the user clicked elsewhere
            SuggestionController.shared.cursorsUpdated(
                textView: controller,
                delegate: completionDelegate,
                position: position
            )
        }
    }
}