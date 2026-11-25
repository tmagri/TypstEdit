import Foundation

// MARK: - Node
//
// The rendered tree. The protocol describes a flat adjacency list; this turns
// it into nodes the SwiftUI layer draws, resolving every dynamic value at build
// time so a redraw never has to re-run a function. Building is separate from
// drawing so the whole tree — bindings, templates, validation, action context —
// can be tested without a window.

/// What one node draws. Properties are already resolved: a `Text`'s `text` is
/// the final string, a `ChoicePicker`'s options are final labels and values.
indirect enum A2UINode: Equatable, Identifiable {
    // Leaf content
    case text(id: String, text: String, variant: String)
    case image(id: String, url: String, description: String, fit: String, variant: String)
    case icon(id: String, name: String, svgPath: String?)
    case video(id: String, url: String)
    case audio(id: String, url: String, description: String)
    case divider(id: String, axis: String)

    // Inputs
    case textField(id: String, label: String, value: String, variant: String, boundPath: String?, errors: [String])
    case checkBox(id: String, label: String, isOn: Bool, boundPath: String?, errors: [String])
    case choicePicker(
        id: String,
        label: String,
        options: [A2UIOption],
        selected: [String],
        multiple: Bool,
        displayStyle: String,
        filterable: Bool,
        boundPath: String?,
        errors: [String]
    )
    case slider(id: String, label: String, value: Double, min: Double, max: Double, boundPath: String?, errors: [String])
    case dateTime(
        id: String,
        label: String,
        value: String,
        enableDate: Bool,
        enableTime: Bool,
        min: String?,
        max: String?,
        boundPath: String?,
        errors: [String]
    )

    // Buttons
    case button(
        id: String,
        label: String,
        isIconOnly: Bool,
        variant: String,
        action: A2UIAction?,
        disabled: Bool,
        disabledReason: String?
    )

    // Layout
    case row(id: String, children: [A2UINode], justify: String, align: String)
    case column(id: String, children: [A2UINode], justify: String, align: String)
    case list(id: String, children: [A2UINode], direction: String, align: String, listStyle: String)
    case card(id: String, child: A2UINode)
    case tabs(id: String, tabs: [A2UITab])
    case modal(id: String, trigger: A2UINode, content: A2UINode, opensOnPress: Bool)

    /// A component whose type this client does not draw, or whose children
    /// could not be resolved. Named rather than dropped, so a missing piece of
    /// the form is visible to the person looking at it.
    case unsupported(id: String, type: String, note: String)

    var id: String {
        switch self {
        case .text(let id, _, _), .image(let id, _, _, _, _), .icon(let id, _, _),
             .video(let id, _), .audio(let id, _, _), .divider(let id, _),
             .textField(let id, _, _, _, _, _), .checkBox(let id, _, _, _, _),
             .choicePicker(let id, _, _, _, _, _, _, _, _), .slider(let id, _, _, _, _, _, _),
             .dateTime(let id, _, _, _, _, _, _, _, _), .button(let id, _, _, _, _, _, _),
             .row(let id, _, _, _), .column(let id, _, _, _), .list(let id, _, _, _, _),
             .card(let id, _), .tabs(let id, _), .modal(let id, _, _, _),
             .unsupported(let id, _, _):
            return id
        }
    }

    /// A copy of this node with its own id replaced. Used only by a template
    /// instantiation: every row built from the same `componentId` would
    /// otherwise share one id, which is the component's identity in the
    /// surface, not the row's — `ForEach` would then merge every row's state
    /// (a `TextField`'s focus, a `Tabs`'s selection) into one.
    func withID(_ newID: String) -> A2UINode {
        switch self {
        case .text(_, let a, let b): return .text(id: newID, text: a, variant: b)
        case .image(_, let a, let b, let c, let d): return .image(id: newID, url: a, description: b, fit: c, variant: d)
        case .icon(_, let a, let b): return .icon(id: newID, name: a, svgPath: b)
        case .video(_, let a): return .video(id: newID, url: a)
        case .audio(_, let a, let b): return .audio(id: newID, url: a, description: b)
        case .divider(_, let a): return .divider(id: newID, axis: a)
        case .textField(_, let a, let b, let c, let d, let e): return .textField(id: newID, label: a, value: b, variant: c, boundPath: d, errors: e)
        case .checkBox(_, let a, let b, let c, let d): return .checkBox(id: newID, label: a, isOn: b, boundPath: c, errors: d)
        case .choicePicker(_, let a, let b, let c, let d, let e, let f, let g, let h):
            return .choicePicker(id: newID, label: a, options: b, selected: c, multiple: d, displayStyle: e, filterable: f, boundPath: g, errors: h)
        case .slider(_, let a, let b, let c, let d, let e, let f): return .slider(id: newID, label: a, value: b, min: c, max: d, boundPath: e, errors: f)
        case .dateTime(_, let a, let b, let c, let d, let e, let f, let g, let h):
            return .dateTime(id: newID, label: a, value: b, enableDate: c, enableTime: d, min: e, max: f, boundPath: g, errors: h)
        case .button(_, let a, let b, let c, let d, let e, let f): return .button(id: newID, label: a, isIconOnly: b, variant: c, action: d, disabled: e, disabledReason: f)
        case .row(_, let a, let b, let c): return .row(id: newID, children: a, justify: b, align: c)
        case .column(_, let a, let b, let c): return .column(id: newID, children: a, justify: b, align: c)
        case .list(_, let a, let b, let c, let d): return .list(id: newID, children: a, direction: b, align: c, listStyle: d)
        case .card(_, let a): return .card(id: newID, child: a)
        case .tabs(_, let a): return .tabs(id: newID, tabs: a)
        case .modal(_, let a, let b, let c): return .modal(id: newID, trigger: a, content: b, opensOnPress: c)
        case .unsupported(_, let a, let b): return .unsupported(id: newID, type: a, note: b)
        }
    }

    /// The marker between a template's real component id and the row index
    /// `instanced` appends. A zero-width space is something no model would
    /// type into a component id, so splitting on it can't collide with a
    /// legitimate id that happens to contain "#".
    static let templateInstanceMarker = "\u{200B}#"

    /// The id a template's Nth instance draws under, so `ForEach` can diff
    /// rows that were all built from the same `componentId` without merging
    /// their state (a `TextField`'s text, a `Tabs`'s selection). The original
    /// component id — what the model wrote, and what an action must report
    /// back — survives after the marker; see `sourceComponentId`.
    func instanced(_ index: Int) -> A2UINode {
        withID("\(id)\(Self.templateInstanceMarker)\(index)")
    }

    /// The id as the model should see it in an action: a plain component id
    /// is reported as-is, and a template row's synthesized id is reported as
    /// the component it was instantiated from.
    var sourceComponentId: String {
        guard let range = id.range(of: Self.templateInstanceMarker) else { return id }
        return String(id[..<range.lowerBound])
    }


    /// Whether this subtree can change while the card is on screen. A card with
    /// no inputs anywhere is static once built, which is the common case for a
    /// notification or a summary, and lets the view skip rebuilding on typing.
    var hasInputs: Bool {
        switch self {
        case .textField, .checkBox, .choicePicker, .slider, .dateTime:
            return true
        case .row(_, let children, _, _), .column(_, let children, _, _), .list(_, let children, _, _, _):
            return children.contains(where: \.hasInputs)
        case .card(_, let child):
            return child.hasInputs
        case .tabs(_, let tabs):
            return tabs.contains { $0.node.hasInputs }
        case .modal(_, let trigger, let content, _):
            return trigger.hasInputs || content.hasInputs
        default:
            return false
        }
    }

    /// Every event action in the tree, shallowest first. Used to answer "did
    /// this press resolve to exactly one action?"
    var actions: [A2UIAction] {
        switch self {
        case .button(_, _, _, _, let action, _, _):
            return action.map { [$0] } ?? []
        case .row(_, let children, _, _), .column(_, let children, _, _), .list(_, let children, _, _, _):
            return children.flatMap(\.actions)
        case .card(_, let child):
            return child.actions
        case .tabs(_, let tabs):
            return tabs.flatMap { $0.node.actions }
        case .modal(_, let trigger, let content, _):
            return trigger.actions + content.actions
        default:
            return []
        }
    }
}

/// One `ChoicePicker` option, resolved to its final label and stable value.
struct A2UIOption: Equatable, Identifiable {
    var label: String
    var value: String
    var id: String { value }
}

/// One `Tabs` entry.
struct A2UITab: Equatable, Identifiable {
    var title: String
    var node: A2UINode
    var id: String { node.id }
}

/// One resolved key of an action's context. An ordered list rather than a
/// dictionary so the context reads back in the order the model wrote it, which
/// keeps the transcript row and the tests stable.
struct A2UIContextEntry: Equatable {
    var key: String
    var value: A2UIValue
}

/// A dispatched `action`. Only server actions (`action.event`) resolve to this;
/// a local `functionCall` action is performed in place and never resumes the
/// tool call, which is what the protocol intends.
struct A2UIAction: Equatable {
    var name: String
    /// Already resolved against the data model, in the order the component
    /// listed them, so the model reads the same keys it wrote.
    var context: [A2UIContextEntry]

    var contextJSON: String {
        var object: [String: Any] = [:]
        for entry in context { object[entry.key] = entry.value.jsonObject }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    var contextSummary: String {
        context.map { "\($0.key)=\($0.value.displayString)" }.joined(separator: ", ")
    }
}

/// One surface rendered for the card, with what the header needs.
struct A2UIRenderedSurface: Identifiable, Equatable {
    let id: String
    let root: A2UINode
    let theme: A2UITheme
}

// MARK: - Builder

enum A2UIBuilder {
    /// How deep a template or component chain may nest. A malformed tree that
    /// points a node at an ancestor would otherwise recurse until the stack
    /// runs out, taking the app with it.
    static let maxDepth = 32

    /// Builds every surface the document can draw. A surface with no `root`
    /// yields nothing; the caller reports that to the model via
    /// `A2UIDocument.rootlessSurfaceIds`.
    static func surfaces(of document: A2UIDocument) -> [A2UIRenderedSurface] {
        document.surfaces.compactMap { surface in
            guard surface.root != nil else { return nil }
            let context = A2UIContext(dataModel: surface.dataModel)
            var effects: [A2UIEffect] = []
            guard let root = node(
                id: "root",
                of: surface,
                context,
                effects: &effects,
                depth: 0,
                visited: []
            ) else { return nil }
            return A2UIRenderedSurface(id: surface.id, root: root, theme: surface.theme)
        }
    }

    /// Builds one component and its subtree. Returns nil for a dangling
    /// reference, which the parent turns into a named placeholder.
    static func node(
        id: String,
        of surface: A2UISurface,
        _ context: A2UIContext,
        effects: inout [A2UIEffect],
        depth: Int,
        visited: Set<String>
    ) -> A2UINode? {
        guard depth < maxDepth else {
            return .unsupported(id: id, type: "depth", note: "Nested deeper than \(maxDepth) levels.")
        }
        guard !visited.contains(id) else {
            return .unsupported(id: id, type: "cycle", note: "This component contains itself.")
        }
        guard let definition = surface.component(id) else { return nil }
        let type = definition["component"]?.stringValue ?? "?"
        var path = visited
        path.insert(id)

        func child(_ key: String) -> A2UINode {
            guard let childId = definition[key]?.stringValue else {
                return .unsupported(id: "\(id)/\(key)", type: type, note: "Missing `\(key)`.")
            }
            return node(id: childId, of: surface, context, effects: &effects, depth: depth + 1, visited: path)
                ?? .unsupported(id: childId, type: type, note: "No component with id '\(childId)'.")
        }

        func childList(_ key: String) -> [A2UINode] {
            guard let raw = definition[key] else {
                return [.unsupported(id: "\(id)/\(key)", type: type, note: "Missing `\(key)`.")]
            }
            switch raw {
            case .array(let ids):
                return ids.compactMap { entry in
                    guard let childId = entry.stringValue else { return nil }
                    return node(id: childId, of: surface, context, effects: &effects, depth: depth + 1, visited: path)
                        ?? .unsupported(id: childId, type: type, note: "No component with id '\(childId)'.")
                }
            case .object(let template):
                // A template instantiates one component per item of a bound
                // list, with relative paths resolved against the item.
                guard let templateId = template["componentId"]?.stringValue,
                      let listPath = template["path"]?.stringValue else {
                    return [.unsupported(id: "\(id)/\(key)", type: type, note: "A template needs componentId and path.")]
                }
                guard let items = surface.value(at: listPath)?.arrayValue else { return [] }
                // Every row is the same component definition, so a row's
                // identity has to come from its item: `templateId#3` keeps the
                // real component id in `sourceComponentId` (what the model
                // named) while giving `ForEach` something unique to diff.
                return items.enumerated().compactMap { index, _ in
                    var itemContext = context
                    itemContext.basePath = A2UIPointer.segments(listPath) + [String(index)]
                    guard let built = node(id: templateId, of: surface, itemContext, effects: &effects, depth: depth + 1, visited: path) else {
                        return A2UINode.unsupported(id: "\(templateId)#\(index)", type: type, note: "No component with id '\(templateId)'.")
                    }
                    return built.instanced(index)
                }
            default:
                return [.unsupported(id: "\(id)/\(key)", type: type, note: "`\(key)` must be an array or a template.")]
            }
        }

        func string(_ key: String, default fallback: String = "") -> String {
            guard let raw = definition[key] else { return fallback }
            return A2UIFunctions.string(raw, context, into: &effects)
        }

        func raw(_ key: String) -> A2UIValue? { definition[key] }

        /// The pointer an input writes back to, when it is bound. A literal
        /// value is local to the view and never reaches the model, which is the
        /// spec's distinction between a default and a binding.
        func boundPath(_ key: String) -> String? {
            definition[key]?.bindingPath
        }

        func errors() -> [String] {
            surface.checkFailures(of: definition, context: context)
        }

        switch type {
        case "Text":
            return .text(id: id, text: string("text"), variant: string("variant", default: "body"))

        case "Image":
            return .image(
                id: id,
                url: string("url"),
                description: string("description"),
                fit: string("fit", default: "fill"),
                variant: string("variant", default: "mediumFeature")
            )

        case "Icon":
            let name = definition["name"]
            return .icon(
                id: id,
                name: name?.stringValue.map { A2UIIcon.systemName(for: $0) } ?? string("name"),
                svgPath: name?.objectValue?["svgPath"]?.stringValue
            )

        case "Video":
            return .video(id: id, url: string("url"))

        case "AudioPlayer":
            return .audio(id: id, url: string("url"), description: string("description"))

        case "Divider":
            return .divider(id: id, axis: string("axis", default: "horizontal"))

        case "TextField":
            let format = string("variant", default: "shortText")
            let value = string("value")
            // The catalog's shorthand `validationRegexp` is a check with a
            // generic message; fold it into the same list the UI shows.
            var failures = errors()
            if let pattern = raw("validationRegexp")?.stringValue, !pattern.isEmpty, !value.isEmpty {
                let expression = try? NSRegularExpression(pattern: pattern)
                let range = NSRange(value.startIndex..<value.endIndex, in: value)
                if let expression, expression.firstMatch(in: value, options: [], range: range) == nil {
                    failures.append("That value is not in the expected format.")
                }
            }
            return .textField(
                id: id,
                label: string("label"),
                value: value,
                variant: format,
                boundPath: boundPath("value"),
                errors: failures
            )

        case "CheckBox":
            let isOn = A2UIFunctions.boolean(raw("value") ?? .bool(false), context, into: &effects) ?? false
            return .checkBox(
                id: id,
                label: string("label"),
                isOn: isOn,
                boundPath: boundPath("value"),
                errors: errors()
            )

        case "ChoicePicker":
            let options = (raw("options")?.arrayValue ?? []).compactMap { entry -> A2UIOption? in
                guard let object = entry.objectValue else { return nil }
                let label = object["label"].map { A2UIFunctions.string($0, context, into: &effects) } ?? ""
                let value = object["value"]?.stringValue ?? label
                return A2UIOption(label: label.isEmpty ? value : label, value: value)
            }
            return .choicePicker(
                id: id,
                label: string("label"),
                options: options,
                selected: A2UIFunctions.stringList(raw("value") ?? .array([]), context, into: &effects),
                multiple: string("variant", default: "mutuallyExclusive") == "multipleSelection",
                displayStyle: string("displayStyle", default: "checkbox"),
                filterable: A2UIFunctions.boolean(raw("filterable") ?? .bool(false), context, into: &effects) ?? false,
                boundPath: boundPath("value"),
                errors: errors()
            )

        case "Slider":
            let value = A2UIFunctions.number(raw("value") ?? .number(0), context, into: &effects) ?? 0
            let minimum = A2UIFunctions.number(raw("min") ?? .number(0), context, into: &effects) ?? 0
            let maximum = A2UIFunctions.number(raw("max") ?? .number(100), context, into: &effects) ?? 100
            return .slider(
                id: id,
                label: string("label"),
                value: value,
                min: minimum,
                max: max(maximum, minimum),
                boundPath: boundPath("value"),
                errors: errors()
            )

        case "DateTimeInput":
            return .dateTime(
                id: id,
                label: string("label"),
                value: string("value"),
                enableDate: A2UIFunctions.boolean(raw("enableDate") ?? .bool(true), context, into: &effects) ?? true,
                enableTime: A2UIFunctions.boolean(raw("enableTime") ?? .bool(false), context, into: &effects) ?? false,
                min: raw("min")?.stringValue,
                max: raw("max")?.stringValue,
                boundPath: boundPath("value"),
                errors: errors()
            )

        case "Button":
            let labelNode = child("child")
            let label: String
            let iconOnly: Bool
            if case .text(_, let text, _) = labelNode {
                label = text
                iconOnly = false
            } else if case .icon = labelNode {
                label = ""
                iconOnly = true
            } else {
                label = ""
                iconOnly = false
            }
            // A Button's `checks` decide whether it can be pressed.
            let failures = errors()
            return .button(
                id: id,
                label: label,
                isIconOnly: iconOnly,
                variant: string("variant", default: "default"),
                action: action(of: definition, context: context, into: &effects),
                disabled: !failures.isEmpty,
                disabledReason: failures.first
            )

        case "Row":
            return .row(
                id: id,
                children: childList("children"),
                justify: string("justify", default: "start"),
                align: string("align", default: "stretch")
            )

        case "Column":
            return .column(
                id: id,
                children: childList("children"),
                justify: string("justify", default: "start"),
                align: string("align", default: "stretch")
            )

        case "List":
            return .list(
                id: id,
                children: childList("children"),
                direction: string("direction", default: "vertical"),
                align: string("align", default: "stretch"),
                listStyle: string("listStyle", default: "none")
            )

        case "Card":
            return .card(id: id, child: child("child"))

        case "Tabs":
            let tabs = (raw("tabs")?.arrayValue ?? []).compactMap { entry -> A2UITab? in
                guard let object = entry.objectValue,
                      let childId = object["child"]?.stringValue else { return nil }
                let title = object["title"].map { A2UIFunctions.string($0, context, into: &effects) } ?? ""
                let node = self.node(id: childId, of: surface, context, effects: &effects, depth: depth + 1, visited: path)
                    ?? .unsupported(id: childId, type: type, note: "No component with id '\(childId)'.")
                return A2UITab(title: title, node: node)
            }
            return .tabs(id: id, tabs: tabs)

        case "Modal":
            let trigger = child("trigger")
            // The spec: the trigger "opens the modal when interacted with".
            // A trigger that already has a server action is a trigger that
            // submits, which is what the button gets; one that does not is
            // marked so the view knows a press should disclose the content
            // rather than do nothing.
            let content = child("content")
            return .modal(
                id: id,
                trigger: trigger,
                content: content,
                opensOnPress: trigger.actions.isEmpty
            )

        default:
            return .unsupported(
                id: id,
                type: type,
                note: "This client draws Text, Image, Icon, Video, AudioPlayer, Row, Column, List, Card, Tabs, Modal, Divider, Button, TextField, CheckBox, ChoicePicker, Slider and DateTimeInput."
            )
        }
    }

    /// Resolves a button's `action`. A `functionCall` action runs immediately
    /// and yields no server action (only `openUrl` is meaningful, and it is
    /// surfaced as an effect by the caller); an `event` action carries its
    /// context resolved against the live data model.
    static func action(
        of definition: [String: A2UIValue],
        context: A2UIContext,
        into effects: inout [A2UIEffect]
    ) -> A2UIAction? {
        guard let action = definition["action"]?.objectValue else { return nil }
        if let function = action["functionCall"] {
            _ = A2UIFunctions.resolve(function, context, into: &effects)
            return nil
        }
        guard let event = action["event"]?.objectValue,
              let name = event["name"]?.stringValue else { return nil }
        var entries: [A2UIContextEntry] = []
        // Sorted keys so the result is stable across JSON dictionary order,
        // which matters for the transcript row and for tests.
        for key in (event["context"]?.objectValue ?? [:]).keys.sorted() {
            guard let raw = event["context"]?.objectValue?[key] else { continue }
            entries.append(A2UIContextEntry(
                key: key,
                value: A2UIFunctions.resolve(raw, context, into: &effects)
            ))
        }
        return A2UIAction(name: name, context: entries)
    }
}

// MARK: - Icons

/// The catalog's fixed icon names, mapped to SF Symbols. A name outside the
/// list is not drawn as a missing glyph; it falls back to a neutral one so the
/// surrounding layout still reads.
enum A2UIIcon {
    static func systemName(for name: String) -> String {
        icons[name] ?? "questionmark.circle"
    }

    private static let icons: [String: String] = [
        "accountCircle": "person.crop.circle",
        "add": "plus",
        "arrowBack": "arrow.left",
        "arrowForward": "arrow.right",
        "attachFile": "paperclip",
        "calendarToday": "calendar",
        "call": "phone",
        "camera": "camera",
        "check": "checkmark",
        "close": "xmark",
        "delete": "trash",
        "download": "arrow.down.circle",
        "edit": "pencil",
        "event": "calendar.badge.clock",
        "error": "exclamationmark.triangle",
        "fastForward": "forward.fill",
        "favorite": "heart.fill",
        "favoriteOff": "heart",
        "folder": "folder",
        "help": "questionmark.circle",
        "home": "house",
        "info": "info.circle",
        "locationOn": "mappin.and.ellipse",
        "lock": "lock",
        "lockOpen": "lock.open",
        "mail": "envelope",
        "menu": "line.3.horizontal",
        "moreVert": "ellipsis",
        "moreHoriz": "ellipsis",
        "notifications": "bell",
        "notificationsOff": "bell.slash",
        "pause": "pause.fill",
        "payment": "creditcard",
        "person": "person",
        "phone": "phone",
        "photo": "photo",
        "play": "play.fill",
        "print": "printer",
        "refresh": "arrow.clockwise",
        "rewind": "backward.fill",
        "search": "magnifyingglass",
        "send": "paperplane",
        "settings": "gearshape",
        "share": "square.and.arrow.up",
        "shoppingCart": "cart",
        "skipNext": "forward.end.fill",
        "skipPrevious": "backward.end.fill",
        "star": "star.fill",
        "starHalf": "star.leadinghalf.filled",
        "starOff": "star",
        "stop": "stop.fill",
        "upload": "arrow.up.circle",
        "visibility": "eye",
        "visibilityOff": "eye.slash",
        "volumeDown": "speaker.wave.1",
        "volumeMute": "speaker.slash",
        "volumeOff": "speaker.slash",
        "volumeUp": "speaker.wave.3",
        "warning": "exclamationmark.triangle.fill",
    ]
}
