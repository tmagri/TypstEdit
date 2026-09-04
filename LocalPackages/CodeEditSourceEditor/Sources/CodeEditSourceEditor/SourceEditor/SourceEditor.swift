//
//  SourceEditor.swift
//  CodeEditSourceEditor
//
//  Created by Lukas Pistrol on 24.05.22.
//

import AppKit
import SwiftUI
import CodeEditTextView
import CodeEditLanguages

/// A SwiftUI View that provides source editing functionality.
public struct SourceEditor: NSViewControllerRepresentable {
    enum TextAPI {
        case binding(Binding<String>)
        case storage(NSTextStorage)
    }

    /// Initializes a new source editor
    /// - Parameters:
    ///   - text: The text content
    ///   - language: The language for syntax highlighting
    ///   - configuration: A configuration object, determining appearance, layout, behaviors  and more.
    ///                    See ``SourceEditorConfiguration``.
    ///   - cursorPositions: The cursor's position in the editor, measured in `(lineNum, columnNum)`
    ///   - highlightProviders: A set of classes you provide to perform syntax highlighting. Leave this as `nil` to use
    ///                         the default `TreeSitterClient` highlighter.
    ///   - undoManager: The undo manager for the text view. Defaults to `nil`, which will create a new CEUndoManager
    ///   - coordinators: Any text coordinators for the view to use. See ``TextViewCoordinator`` for more information.
    public init(
        _ text: Binding<String>,
        language: CodeLanguage,
        configuration: SourceEditorConfiguration,
        state: Binding<SourceEditorState>,
        highlightProviders: [any HighlightProviding]? = nil,
        undoManager: CEUndoManager? = nil,
        coordinators: [any TextViewCoordinator] = [],
        completionDelegate: CodeSuggestionDelegate? = nil,
        jumpToDefinitionDelegate: JumpToDefinitionDelegate? = nil
    ) {
        self.text = .binding(text)
        self.language = language
        self.configuration = configuration
        self._state = state
        self.highlightProviders = highlightProviders
        self.undoManager = undoManager
        self.coordinators = coordinators
        self.completionDelegate = completionDelegate
        self.jumpToDefinitionDelegate = jumpToDefinitionDelegate
    }

    /// Initializes a new source editor
    /// - Parameters:
    ///   - text: The text content
    ///   - language: The language for syntax highlighting
    ///   - configuration: A configuration object, determining appearance, layout, behaviors  and more.
    ///                    See ``SourceEditorConfiguration``.
    ///   - cursorPositions: The cursor's position in the editor, measured in `(lineNum, columnNum)`
    ///   - highlightProviders: A set of classes you provide to perform syntax highlighting. Leave this as `nil` to use
    ///                         the default `TreeSitterClient` highlighter.
    ///   - undoManager: The undo manager for the text view. Defaults to `nil`, which will create a new CEUndoManager
    ///   - coordinators: Any text coordinators for the view to use. See ``TextViewCoordinator`` for more information.
    public init(
        _ text: NSTextStorage,
        language: CodeLanguage,
        configuration: SourceEditorConfiguration,
        state: Binding<SourceEditorState>,
        highlightProviders: [any HighlightProviding]? = nil,
        undoManager: CEUndoManager? = nil,
        coordinators: [any TextViewCoordinator] = [],
        completionDelegate: CodeSuggestionDelegate? = nil,
        jumpToDefinitionDelegate: JumpToDefinitionDelegate? = nil
    ) {
        self.text = .storage(text)
        self.language = language
        self.configuration = configuration
        self._state = state
        self.highlightProviders = highlightProviders
        self.undoManager = undoManager
        self.coordinators = coordinators
        self.completionDelegate = completionDelegate
        self.jumpToDefinitionDelegate = jumpToDefinitionDelegate
    }

    var text: TextAPI
    var language: CodeLanguage
    var configuration: SourceEditorConfiguration
    @Binding var state: SourceEditorState
    var highlightProviders: [any HighlightProviding]?
    var undoManager: CEUndoManager?
    var coordinators: [any TextViewCoordinator]
    weak var completionDelegate: CodeSuggestionDelegate?
    weak var jumpToDefinitionDelegate: JumpToDefinitionDelegate?

    public typealias NSViewControllerType = TextViewController

    public func makeNSViewController(context: Context) -> TextViewController {
        let controller = TextViewController(
            string: "",
            language: language,
            configuration: configuration,
            cursorPositions: state.cursorPositions ?? [],
            highlightProviders: context.coordinator.highlightProviders,
            undoManager: undoManager,
            coordinators: coordinators
        )
        switch text {
        case .binding(let binding):
            controller.textView.setText(binding.wrappedValue)
        case .storage(let textStorage):
            controller.textView.setTextStorage(textStorage)
        }
        if controller.textView == nil {
            controller.loadView()
        }
        if !(state.cursorPositions?.isEmpty ?? true) {
            controller.setCursorPositions(state.cursorPositions ?? [])
        }

        controller.completionDelegate = completionDelegate
        controller.jumpToDefinitionModel?.delegate = jumpToDefinitionDelegate

        context.coordinator.setController(controller)
        return controller
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(text: text, editorState: $state, highlightProviders: highlightProviders)
    }

    public func updateNSViewController(_ controller: TextViewController, context: Context) {
        controller.completionDelegate = completionDelegate
        controller.jumpToDefinitionModel?.delegate = jumpToDefinitionDelegate

        context.coordinator.updateHighlightProviders(highlightProviders)

        // Prevent infinite loop of update notifications
        if context.coordinator.isUpdateFromTextView {
            context.coordinator.isUpdateFromTextView = false
        } else {
            context.coordinator.isUpdatingFromRepresentable = true
            updateControllerWithState(state, controller: controller)
            context.coordinator.isUpdatingFromRepresentable = false
        }

        // Reconcile the text view's displayed text with the binding.
        // The plain String binding is one-way upward (text view -> binding) via the coordinator;
        // downward (binding -> text view) only happens at init. Programmatic changes to the binding
        // (paste, formatting actions, restoreContent) therefore need to be pushed back down here,
        // otherwise the editor can display stale/blank text while the model is correct.
        syncTextIfNeeded(controller: controller)

        // Do manual diffing to reduce the amount of reloads.
        // This helps a lot in view performance, as it otherwise gets triggered on each environment change.
        guard !paramsAreEqual(controller: controller, coordinator: context.coordinator) else {
            return
        }

        if controller.language != language {
            controller.language = language
        }
        controller.configuration = configuration
        updateHighlighting(controller, coordinator: context.coordinator)

        controller.reloadUI()
        return
    }

    /// Reconciles the text view's displayed string with the SwiftUI `String` binding.
    /// Only acts when the two have diverged (e.g. a programmatic edit to the binding that did not
    /// route through the text view). This is the downward (binding -> text view) sync that the
    /// `String`-binding initializer otherwise lacks, and prevents the editor from going blank while
    /// the model is up to date.
    private func syncTextIfNeeded(controller: TextViewController) {
        guard case .binding(let binding) = text else { return }
        let bindingText = binding.wrappedValue
        guard let textView = controller.textView else { return }
        let current = textView.string
        guard current != bindingText else { return }

        // Preserve cursor as best we can across the resync.
        let storageLength = (current as NSString).length
        let previousRange: NSRange = textView.selectionManager.textSelections.first?.range
            ?? NSRange(location: storageLength, length: 0)
        let clampedLocation = max(0, min(previousRange.location, (bindingText as NSString).length))

        if storageLength == 0 {
            textView.setText(bindingText)
        } else {
            textView.replaceCharacters(
                in: NSRange(location: 0, length: storageLength),
                with: bindingText,
                skipUpdateSelection: true
            )
        }

        // Restore a sane caret position after the full replace.
        textView.selectionManager.setSelectedRange(NSRange(location: clampedLocation, length: 0))
        textView.updateFrameIfNeeded()
        textView.layoutManager.layoutLines()
        textView.needsDisplay = true
    }

    private func updateControllerWithState(_ state: SourceEditorState, controller: TextViewController) {
        if let cursorPositions = state.cursorPositions, cursorPositions != state.cursorPositions {
            controller.setCursorPositions(cursorPositions)
        }

        let scrollView = controller.scrollView
        if let scrollPosition = state.scrollPosition, scrollPosition != scrollView?.contentView.bounds.origin {
            controller.scrollView.scroll(controller.scrollView.contentView, to: scrollPosition)
            controller.scrollView.reflectScrolledClipView(controller.scrollView.contentView)
            controller.gutterView.needsDisplay = true
            NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: controller.textView)
        }

        if let findText = state.findText, findText != controller.findViewController?.viewModel.findText {
            controller.findViewController?.viewModel.findText = findText
        }

        if let replaceText = state.replaceText, replaceText != controller.findViewController?.viewModel.replaceText {
            controller.findViewController?.viewModel.replaceText = replaceText
        }

        if let findPanelVisible = state.findPanelVisible,
           let findController = controller.findViewController,
           findController.viewModel.isShowingFindPanel != findPanelVisible {
            // Needs to be on the next runloop, not many great ways to do this besides a dispatch...
            DispatchQueue.main.async {
                if findPanelVisible {
                    findController.showFindPanel()
                } else {
                    findController.hideFindPanel()
                }
            }
        }
    }

    private func updateHighlighting(_ controller: TextViewController, coordinator: Coordinator) {
        if !areHighlightProvidersEqual(controller: controller, coordinator: coordinator) {
            controller.setHighlightProviders(coordinator.highlightProviders)
        }
    }

    /// Checks if the controller needs updating.
    /// - Parameter controller: The controller to check.
    /// - Returns: True, if the controller's parameters should be updated.
    func paramsAreEqual(controller: NSViewControllerType, coordinator: Coordinator) -> Bool {
        controller.language.id == language.id &&
        controller.configuration == configuration &&
        areHighlightProvidersEqual(controller: controller, coordinator: coordinator)
    }

    private func areHighlightProvidersEqual(controller: TextViewController, coordinator: Coordinator) -> Bool {
        controller.highlightProviders.map { ObjectIdentifier($0) }
        == coordinator.highlightProviders.map { ObjectIdentifier($0) }
    }
}
