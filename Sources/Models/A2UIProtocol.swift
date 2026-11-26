import Foundation

// MARK: - Value
//
// A2UI (Agent-to-User Interface, v0.9) is Google's open protocol for an agent
// to send a declarative description of an interface — cards, rows, text
// fields, buttons — as a stream of JSON messages, which the host app renders
// with its own native widgets. Nothing is executed: the server describes, the
// client draws and validates.
//
// This file is the protocol half, kept free of SwiftUI on purpose. The rule it
// follows throughout: a *structural* problem with a message (an unknown message
// type, a surface that was never created) is an error reported back to the
// model, which is the protocol's own prompt-generate-validate loop; a *cosmetic*
// problem (a dangling child reference, an unknown component type) is rendered
// as a placeholder. A broken card must not cost the turn, and a silently
// dropped component must not look like the model never sent it.

/// One JSON value, in a shape the protocol code can resolve data paths and
/// function calls against. JSONSerialization's `Any` cannot tell a boolean from
/// the number 1, and `NSNull` has no natural equality, so the stream is decoded
/// into this instead of being passed around as `[String: Any]`.
enum A2UIValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([A2UIValue])
    case object([String: A2UIValue])
    case null

    /// Decodes a JSONSerialization result. Booleans are checked by their
    /// CoreFoundation type, because `NSNumber(1) as? Bool` also succeeds and
    /// would turn every `1` in a data model into `true`.
    init?(json: Any) {
        switch json {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            var decoded: [A2UIValue] = []
            decoded.reserveCapacity(array.count)
            for entry in array {
                guard let value = A2UIValue(json: entry) else { return nil }
                decoded.append(value)
            }
            self = .array(decoded)
        case let object as [String: Any]:
            var decoded: [String: A2UIValue] = [:]
            decoded.reserveCapacity(object.count)
            for (key, entry) in object {
                guard let value = A2UIValue(json: entry) else { return nil }
                decoded[key] = value
            }
            self = .object(decoded)
        default:
            return nil
        }
    }

    /// Parses a JSON document, a single envelope, or a JSONL stream of
    /// envelopes. The tool accepts all three because a model that has read the
    /// spec writes JSONL, and a model using function calling more naturally
    /// writes an array.
    static func parseEnvelopes(_ text: String) throws -> [A2UIValue] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if let data = trimmed.data(using: .utf8),
           let any = try? JSONSerialization.jsonObject(with: data),
           let value = A2UIValue(json: any) {
            switch value {
            case .array(let entries):
                // An array of envelopes, or the single `messages` array of
                // a tool call that arrived as a string.
                return entries
            default:
                return [value]
            }
        }
        // Newline-delimited JSON: the protocol's canonical transport shape.
        var envelopes: [A2UIValue] = []
        for line in trimmed.split(separator: "\n") {
            let candidate = line.trimmingCharacters(in: .whitespaces)
            guard !candidate.isEmpty else { continue }
            guard let data = candidate.data(using: .utf8),
                  let any = try? JSONSerialization.jsonObject(with: data),
                  let value = A2UIValue(json: any) else {
                throw A2UIError(
                    surfaceId: "",
                    path: "/messages",
                    message: "Not valid JSON: \(candidate.prefix(80))"
                )
            }
            envelopes.append(value)
        }
        return envelopes
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var arrayValue: [A2UIValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [String: A2UIValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// A JSON-pointer binding, `{"path": "/user/name"}`.
    var bindingPath: String? {
        guard case .object(let object) = self, object.count == 1 else { return nil }
        return object["path"]?.stringValue
    }

    /// A function call, `{"call": "required", "args": {...}}`.
    var functionCall: (name: String, args: [String: A2UIValue])? {
        guard case .object(let object) = self,
              let name = object["call"]?.stringValue else { return nil }
        return (name, object["args"]?.objectValue ?? [:])
    }

    /// The value as text, for the places the protocol interpolates a
    /// non-string: numbers and booleans use their standard form, null is empty,
    /// and objects and arrays are JSON so nothing is silently lost.
    var displayString: String {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            // `2.0` reads as noise in a form field; integral values print as
            // integers.
            if value.rounded() == value, abs(value) < 1e15 {
                return String(Int(value))
            }
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .null:
            return ""
        case .array, .object:
            return jsonText ?? ""
        }
    }

    /// Compact JSON, for the tool result's data model snapshot.
    var jsonText: String? {
        guard let data = try? JSONSerialization.data(
            withJSONObject: jsonObject,
            options: [.sortedKeys]
        ) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Pretty JSON, for anywhere a person reads it.
    var prettyJSONText: String? {
        guard let data = try? JSONSerialization.data(
            withJSONObject: jsonObject,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    var jsonObject: Any {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return value
        case .bool(let value):
            return value
        case .null:
            return NSNull()
        case .array(let values):
            return values.map(\.jsonObject)
        case .object(let object):
            return object.mapValues(\.jsonObject)
        }
    }

    /// What `required` means in the catalog: not null, not an empty string, not
    /// an empty list.
    var isPresent: Bool {
        switch self {
        case .null:
            return false
        case .string(let value):
            return !value.isEmpty
        case .array(let value):
            return !value.isEmpty
        default:
            return true
        }
    }
}

// MARK: - Errors

/// A protocol-level failure, in the shape the spec's client-to-server message
/// uses, so it can be handed to the model verbatim and the model can correct it.
struct A2UIError: Error, Equatable, LocalizedError {
    /// `VALIDATION_FAILED` for a message that does not fit the schema, or a
    /// short generic code (`UNKNOWN_SURFACE`, `NO_ROOT`, …).
    var code: String = "VALIDATION_FAILED"
    /// The surface the failure concerns, or "" when it is the stream itself.
    var surfaceId: String
    /// JSON pointer into the offending message, e.g. `/messages/0/createSurface`.
    var path: String
    var message: String

    var errorDescription: String? { "\(code) at \(path): \(message)" }

    /// The envelope the model reads back. Named keys make a batch of errors
    /// scannable, and the exact path is what makes a correction possible.
    var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "code": code,
            "path": path,
            "message": message,
        ]
        if !surfaceId.isEmpty { object["surfaceId"] = surfaceId }
        return object
    }
}

// MARK: - JSON Pointer

/// JSON Pointer (RFC 6901) over `A2UIValue`. A2UI uses pointers both as data
/// bindings and as the `path` of a `updateDataModel` message, so getting the
/// escaping right matters: a key that legitimately contains `/` is `~1`.
enum A2UIPointer {
    static let root = "/"

    /// Splits a pointer into unescaped segments. A leading `/` is required for
    /// an absolute pointer; the empty string is the root.
    static func segments(_ pointer: String) -> [String] {
        guard pointer != "/", !pointer.isEmpty else { return [] }
        var text = pointer
        if text.hasPrefix("/") { text.removeFirst() }
        return text.split(separator: "/", omittingEmptySubsequences: false).map {
            $0.replacingOccurrences(of: "~1", with: "/")
                .replacingOccurrences(of: "~0", with: "~")
        }
    }

    static func escape(_ segment: String) -> String {
        segment.replacingOccurrences(of: "~", with: "~0")
            .replacingOccurrences(of: "/", with: "~1")
    }

    static func join(_ segments: [String]) -> String {
        guard !segments.isEmpty else { return "/" }
        return "/" + segments.map(escape).joined(separator: "/")
    }

    /// Reads the value at `segments`. Missing keys read as `nil`, which the
    /// protocol treats as "undefined" during progressive rendering.
    static func value(at segments: [String], in root: A2UIValue) -> A2UIValue? {
        var current = root
        for segment in segments {
            switch current {
            case .object(let object):
                guard let next = object[segment] else { return nil }
                current = next
            case .array(let array):
                guard let index = Int(segment), array.indices.contains(index) else { return nil }
                current = array[index]
            default:
                return nil
            }
        }
        return current
    }

    /// Reads a pointer, resolving a relative path against `base` (the path of
    /// the collection item a template instantiated). The protocol extends JSON
    /// Pointer this way so a template can say `firstName`.
    static func value(at pointer: String, base: [String] = [], in root: A2UIValue) -> A2UIValue? {
        let resolved = pointer.hasPrefix("/") || pointer.isEmpty
            ? segments(pointer)
            : base + segments(pointer)
        return value(at: resolved, in: root)
    }

    /// Upsert semantics from the spec: an existing path is replaced, a missing
    /// one is created, and `nil` removes it — for an array that leaves a hole
    /// (`null`) so later indices keep their meaning.
    static func set(_ value: A2UIValue?, at segments: [String], in root: inout A2UIValue) {
        guard let head = segments.first else {
            root = value ?? .object([:])
            return
        }
        let rest = Array(segments.dropFirst())
        switch root {
        case .object(var object):
            if rest.isEmpty {
                if let value { object[head] = value } else { object.removeValue(forKey: head) }
            } else {
                var child = object[head] ?? (Int(rest[0]) != nil ? .array([]) : .object([:]))
                set(value, at: rest, in: &child)
                object[head] = child
            }
            root = .object(object)
        case .array(var array):
            guard let index = Int(head) else {
                // A non-numeric segment cannot address an array; the spec calls
                // that an error, and rewriting the container would lose data.
                return
            }
            while array.count <= index { array.append(.null) }
            if rest.isEmpty {
                array[index] = value ?? .null
            } else {
                var child = array[index]
                if case .null = child {
                    child = Int(rest[0]) != nil ? .array([]) : .object([:])
                }
                set(value, at: rest, in: &child)
                array[index] = child
            }
            root = .array(array)
        default:
            // Writing through a scalar: replace it with the container the path
            // needs rather than dropping the update.
            var child: A2UIValue = Int(head) != nil ? .array([]) : .object([:])
            set(value, at: segments, in: &child)
            root = child
        }
    }
}

// MARK: - Theme

struct A2UITheme: Equatable, Sendable {
    var primaryColor: String? = nil
    var agentDisplayName: String? = nil
    var iconURL: String? = nil

    /// The same colour as an `#RRGGBB` hex string, validated. Anything else is
    /// ignored: the renderer falls back to the system accent colour rather than
    /// painting the card with a typo.
    var rgb: (red: Double, green: Double, blue: Double)? {
        guard let primaryColor, primaryColor.count == 7, primaryColor.hasPrefix("#") else { return nil }
        let hex = String(primaryColor.dropFirst())
        guard let value = UInt32(hex, radix: 16) else { return nil }
        return (
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

// MARK: - Messages

/// The four server-to-client envelopes of v0.9. `version` is accepted and
/// ignored: only v0.9 is implemented, and rejecting a v0.8 stream would turn a
/// version mismatch into a dead card instead of a visible form.
enum A2UIMessage: Equatable {
    case createSurface(surfaceId: String, catalogId: String, theme: A2UITheme, sendDataModel: Bool)
    case updateComponents(surfaceId: String, components: [[String: A2UIValue]])
    case updateDataModel(surfaceId: String, path: String?, value: A2UIValue?)
    case deleteSurface(surfaceId: String)

    var surfaceId: String {
        switch self {
        case .createSurface(let id, _, _, _): return id
        case .updateComponents(let id, _): return id
        case .updateDataModel(let id, _, _): return id
        case .deleteSurface(let id): return id
        }
    }

    var kind: String {
        switch self {
        case .createSurface: return "createSurface"
        case .updateComponents: return "updateComponents"
        case .updateDataModel: return "updateDataModel"
        case .deleteSurface: return "deleteSurface"
        }
    }

    /// Parses one envelope. `index` is only used to build the error path.
    static func parse(_ envelope: A2UIValue, index: Int) throws -> A2UIMessage {
        let prefix = "/messages/\(index)"
        guard case .object(let object) = envelope else {
            throw A2UIError(surfaceId: "", path: prefix, message: "Each message must be a JSON object.")
        }
        let recognised = ["createSurface", "updateComponents", "updateDataModel", "deleteSurface"]
        let present = recognised.filter { object[$0] != nil }
        guard present.count == 1, let kind = present.first else {
            throw A2UIError(
                surfaceId: "",
                path: prefix,
                message: present.isEmpty
                    ? "A message must contain exactly one of \(recognised.joined(separator: ", "))."
                    : "A message contained more than one of \(present.joined(separator: ", ")); send one envelope per message."
            )
        }
        guard let body = object[kind]?.objectValue else {
            throw A2UIError(surfaceId: "", path: "\(prefix)/\(kind)", message: "\(kind) must be an object.")
        }
        guard let surfaceId = body["surfaceId"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !surfaceId.isEmpty else {
            throw A2UIError(surfaceId: "", path: "\(prefix)/\(kind)/surfaceId", message: "\(kind) needs a non-empty surfaceId.")
        }

        switch kind {
        case "createSurface":
            guard let catalogId = body["catalogId"]?.stringValue, !catalogId.isEmpty else {
                throw A2UIError(
                    surfaceId: surfaceId,
                    path: "\(prefix)/createSurface/catalogId",
                    message: "createSurface needs catalogId. Use https://a2ui.org/specification/v0_9/catalogs/basic/catalog.json."
                )
            }
            var theme = A2UITheme()
            if let raw = body["theme"]?.objectValue {
                theme.primaryColor = raw["primaryColor"]?.stringValue
                theme.agentDisplayName = raw["agentDisplayName"]?.stringValue
                theme.iconURL = raw["iconUrl"]?.stringValue
            }
            return .createSurface(
                surfaceId: surfaceId,
                catalogId: catalogId,
                theme: theme,
                sendDataModel: body["sendDataModel"]?.boolValue ?? false
            )

        case "updateComponents":
            guard let raw = body["components"]?.arrayValue else {
                throw A2UIError(
                    surfaceId: surfaceId,
                    path: "\(prefix)/updateComponents/components",
                    message: "updateComponents needs a components array."
                )
            }
            var components: [[String: A2UIValue]] = []
            for (offset, entry) in raw.enumerated() {
                guard let component = entry.objectValue else {
                    throw A2UIError(
                        surfaceId: surfaceId,
                        path: "\(prefix)/updateComponents/components/\(offset)",
                        message: "Each component must be an object."
                    )
                }
                components.append(component)
            }
            return .updateComponents(surfaceId: surfaceId, components: components)

        case "updateDataModel":
            return .updateDataModel(
                surfaceId: surfaceId,
                path: body["path"]?.stringValue,
                // An absent `value` key removes the path; an explicit `null`
                // also removes it, per the spec.
                value: body["value"].flatMap { $0 == .null ? nil : $0 }
            )

        default:
            return .deleteSurface(surfaceId: surfaceId)
        }
    }
}

// MARK: - Surface

/// One rendered surface: its component tree (as an adjacency list of raw
/// component objects), its data model, and its theme. Components are kept as
/// raw property bags so an unknown component type survives a round trip and can
/// be named back to the model instead of vanishing.
struct A2UISurface: Identifiable, Equatable {
    let id: String
    var catalogId: String
    var theme: A2UITheme
    var sendDataModel: Bool
    /// Component definitions by id, in the order they were first described.
    private(set) var components: [String: [String: A2UIValue]] = [:]
    private(set) var order: [String] = []
    var dataModel: A2UIValue = .object([:])

    init(surfaceId: String, catalogId: String, theme: A2UITheme = A2UITheme(), sendDataModel: Bool = false) {
        self.id = surfaceId
        self.catalogId = catalogId
        self.theme = theme
        self.sendDataModel = sendDataModel
    }

    /// Upsert by component id. An update replaces the definition in place so
    /// the tree keeps its order; a new id appends.
    mutating func upsert(_ definitions: [[String: A2UIValue]]) {
        for definition in definitions {
            guard let componentId = definition["id"]?.stringValue, !componentId.isEmpty else { continue }
            if components[componentId] == nil { order.append(componentId) }
            components[componentId] = definition
        }
    }

    func component(_ componentId: String) -> [String: A2UIValue]? { components[componentId] }

    var root: [String: A2UIValue]? { components["root"] }

    /// How many components are defined, for the tool row's summary.
    var componentCount: Int { components.count }

    /// Applies a data model update at a pointer.
    mutating func applyDataModel(path: String?, value: A2UIValue?) {
        guard let path, path != "/", !path.isEmpty else {
            if let value, case .object = value {
                dataModel = value
            } else if let value {
                dataModel = .object(["value": value])
            }
            return
        }
        A2UIPointer.set(value, at: A2UIPointer.segments(path), in: &dataModel)
    }

    /// Writes one bound value, which is what an input component does on every
    /// keystroke. Two-way binding is local to the client; nothing reaches the
    /// model until an action is dispatched.
    mutating func setBoundValue(_ value: A2UIValue, at path: String) {
        A2UIPointer.set(value, at: A2UIPointer.segments(path), in: &dataModel)
    }

    func value(at path: String, base: [String] = []) -> A2UIValue? {
        A2UIPointer.value(at: path, base: base, in: dataModel)
    }
}

// MARK: - Document

/// The live set of surfaces for one conversation. Applying a stream is pure
/// except for the recorded errors, which is what lets the whole protocol be
/// tested without a window on screen.
struct A2UIDocument: Equatable {
    private(set) var surfaces: [A2UISurface] = []
    private(set) var errors: [A2UIError] = []

    /// Surfaces in creation order, which is the order the card draws them.
    var isEmpty: Bool { surfaces.isEmpty }
    var surfaceIds: [String] { surfaces.map(\.id) }

    func surface(_ surfaceId: String) -> A2UISurface? {
        surfaces.first { $0.id == surfaceId }
    }

    /// Writes one bound input value into one surface's data model. The view
    /// passes the surface the input was drawn on, so a card with two surfaces
    /// that both bind `/name` cannot update the wrong one.
    mutating func setBoundValue(_ value: A2UIValue, at path: String, on surfaceId: String) {
        guard let index = surfaces.firstIndex(where: { $0.id == surfaceId }) else { return }
        surfaces[index].setBoundValue(value, at: path)
        // An input's `checks` and any bound label must re-evaluate against the
        // new value, which happens on the next render; nothing else to do here.
    }

    private mutating func update(_ surfaceId: String, _ body: (inout A2UISurface) -> Void) {
        guard let index = surfaces.firstIndex(where: { $0.id == surfaceId }) else { return }
        body(&surfaces[index])
    }

    /// Applies one envelope. Errors are collected, never thrown, so one bad
    /// message in a batch does not discard the good ones.
    mutating func apply(_ message: A2UIMessage, at index: Int) {
        let prefix = "/messages/\(index)/\(message.kind)"
        switch message {
        case .createSurface(let surfaceId, let catalogId, let theme, let sendDataModel):
            guard surface(surfaceId) == nil else {
                errors.append(A2UIError(
                    surfaceId: surfaceId,
                    path: "\(prefix)/surfaceId",
                    message: "Surface '\(surfaceId)' already exists. Delete it first, or reuse it with updateComponents/updateDataModel — a surfaceId is unique for the life of the session."
                ))
                return
            }
            surfaces.append(A2UISurface(
                surfaceId: surfaceId,
                catalogId: catalogId,
                theme: theme,
                sendDataModel: sendDataModel
            ))

        case .updateComponents(let surfaceId, let components):
            guard surface(surfaceId) != nil else {
                errors.append(A2UIError(
                    code: "UNKNOWN_SURFACE",
                    surfaceId: surfaceId,
                    path: prefix,
                    message: "No surface '\(surfaceId)'. Send createSurface for it first."
                ))
                return
            }
            update(surfaceId) { $0.upsert(components) }

        case .updateDataModel(let surfaceId, let path, let value):
            guard surface(surfaceId) != nil else {
                errors.append(A2UIError(
                    code: "UNKNOWN_SURFACE",
                    surfaceId: surfaceId,
                    path: prefix,
                    message: "No surface '\(surfaceId)'. Send createSurface for it first."
                ))
                return
            }
            update(surfaceId) { $0.applyDataModel(path: path, value: value) }

        case .deleteSurface(let surfaceId):
            guard surface(surfaceId) != nil else {
                errors.append(A2UIError(
                    code: "UNKNOWN_SURFACE",
                    surfaceId: surfaceId,
                    path: prefix,
                    message: "No surface '\(surfaceId)' to delete."
                ))
                return
            }
            surfaces.removeAll { $0.id == surfaceId }
        }
    }

    /// Applies a whole stream and reports whether anything is renderable.
    mutating func apply(_ messages: [A2UIMessage]) {
        for (index, message) in messages.enumerated() {
            apply(message, at: index)
        }
    }

    /// A surface with no `root` draws nothing, so the model is told rather than
    /// left looking at an empty card.
    var rootlessSurfaceIds: [String] {
        surfaces.filter { $0.root == nil }.map(\.id)
    }
}

// MARK: - Function context

/// The scope one component is resolved in: the data model, plus where relative
/// paths start (the item path of the collection a template instantiated).
struct A2UIContext: Equatable {
    var dataModel: A2UIValue
    var basePath: [String] = []

    func value(_ pointer: String) -> A2UIValue? {
        A2UIPointer.value(at: pointer, base: basePath, in: dataModel)
    }
}

/// A side effect a function asked for. `openUrl` is the only one in the basic
/// catalog, and it is never performed inside evaluation — the agent performs it
/// so a URL is opened once, by the app, not as a side effect of a redraw.
enum A2UIEffect: Equatable {
    case openURL(String)
}

// MARK: - Functions

/// The catalog's client-side functions. These are the "client logic" half of
/// the protocol: validation checks, and the dynamic values a component can
/// compute (`formatString`, `formatDate`, …). Nothing here executes model-
/// supplied code — a function is looked up by name, and an unknown name is a
/// visible failure rather than a silent empty string.
enum A2UIFunctions {
    static let catalogId = "https://a2ui.org/specification/v0_9/catalogs/basic/catalog.json"

    /// Resolves a `DynamicValue`: a literal passes through, `{"path": …}` reads
    /// the data model, `{"call": …}` runs the function.
    static func resolve(_ value: A2UIValue, _ context: A2UIContext, into effects: inout [A2UIEffect]) -> A2UIValue {
        if let path = value.bindingPath {
            return context.value(path) ?? .null
        }
        if let call = value.functionCall {
            return callFunction(call.name, args: call.args, context, into: &effects)
        }
        return value
    }

    static func string(_ value: A2UIValue, _ context: A2UIContext, into effects: inout [A2UIEffect]) -> String {
        resolve(value, context, into: &effects).displayString
    }

    static func number(_ value: A2UIValue, _ context: A2UIContext, into effects: inout [A2UIEffect]) -> Double? {
        let resolved = resolve(value, context, into: &effects)
        switch resolved {
        case .number(let number): return number
        case .string(let text): return Double(text.trimmingCharacters(in: .whitespaces))
        case .bool(let flag): return flag ? 1 : 0
        default: return nil
        }
    }

    static func boolean(_ value: A2UIValue, _ context: A2UIContext, into effects: inout [A2UIEffect]) -> Bool? {
        let resolved = resolve(value, context, into: &effects)
        switch resolved {
        case .bool(let flag): return flag
        case .number(let number): return number != 0
        case .string(let text):
            switch text.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0", "": return false
            default: return nil
            }
        case .null: return nil
        case .array(let values): return !values.isEmpty
        case .object: return true
        }
    }

    static func stringList(_ value: A2UIValue, _ context: A2UIContext, into effects: inout [A2UIEffect]) -> [String] {
        switch resolve(value, context, into: &effects) {
        case .array(let values):
            return values.map(\.displayString)
        case .string(let text):
            // A single value bound to a multi-select is read as one selection
            // rather than dropped.
            return text.isEmpty ? [] : [text]
        default:
            return []
        }
    }

    /// Runs one named function. Unknown names resolve to `null` and record the
    /// miss in the effects list's sibling (see `lastUnknownFunction`) — the
    /// renderer shows a placeholder so a typo is visible.
    static func callFunction(
        _ name: String,
        args: [String: A2UIValue],
        _ context: A2UIContext,
        into effects: inout [A2UIEffect]
    ) -> A2UIValue {
        switch name {
        case "required":
            guard let value = args["value"] else { return .bool(false) }
            return .bool(resolve(value, context, into: &effects).isPresent)

        case "regex":
            let value = string(args["value"] ?? .null, context, into: &effects)
            let pattern = string(args["pattern"] ?? .null, context, into: &effects)
            guard let expression = try? NSRegularExpression(pattern: pattern) else {
                // An invalid pattern is the agent's bug: report it as a failed
                // check so the message the model wrote is what the user sees.
                return .bool(false)
            }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            return .bool(expression.firstMatch(in: value, options: [], range: range) != nil)

        case "length":
            let value = string(args["value"] ?? .null, context, into: &effects)
            let count = value.count
            var passes = true
            if let min = number(args["min"] ?? .null, context, into: &effects) { passes = passes && Double(count) >= min }
            if let max = number(args["max"] ?? .null, context, into: &effects) { passes = passes && Double(count) <= max }
            return .bool(passes)

        case "numeric":
            guard let value = number(args["value"] ?? .null, context, into: &effects) else { return .bool(false) }
            var passes = true
            if let min = number(args["min"] ?? .null, context, into: &effects) { passes = passes && value >= min }
            if let max = number(args["max"] ?? .null, context, into: &effects) { passes = passes && value <= max }
            return .bool(passes)

        case "email":
            let value = string(args["value"] ?? .null, context, into: &effects)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .bool(isEmail(value))

        case "formatString":
            let template = string(args["value"] ?? .null, context, into: &effects)
            return .string(interpolate(template, context, into: &effects))

        case "formatNumber":
            guard let value = number(args["value"] ?? .null, context, into: &effects) else { return .string("") }
            return .string(formatNumber(
                value,
                decimals: number(args["decimals"] ?? .null, context, into: &effects),
                grouping: boolean(args["grouping"] ?? .bool(true), context, into: &effects) ?? true,
                currency: nil
            ))

        case "formatCurrency":
            guard let value = number(args["value"] ?? .null, context, into: &effects) else { return .string("") }
            let code = string(args["currency"] ?? .null, context, into: &effects)
            return .string(formatNumber(
                value,
                decimals: number(args["decimals"] ?? .null, context, into: &effects),
                grouping: boolean(args["grouping"] ?? .bool(true), context, into: &effects) ?? true,
                currency: code.isEmpty ? nil : code
            ))

        case "formatDate":
            let raw = resolve(args["value"] ?? .null, context, into: &effects)
            let pattern = string(args["format"] ?? .null, context, into: &effects)
            return .string(formatDate(raw, pattern: pattern))

        case "pluralize":
            guard let count = number(args["value"] ?? .null, context, into: &effects) else { return .string("") }
            return .string(pluralize(count, args: args, context, into: &effects))

        case "openUrl":
            let url = string(args["url"] ?? .null, context, into: &effects)
            effects.append(.openURL(url))
            return .null

        case "and":
            let values = args["values"]?.arrayValue ?? []
            return .bool(values.allSatisfy { boolean($0, context, into: &effects) ?? false })

        case "or":
            let values = args["values"]?.arrayValue ?? []
            return .bool(values.contains { boolean($0, context, into: &effects) ?? false })

        case "not":
            return .bool(!(boolean(args["value"] ?? .null, context, into: &effects) ?? false))

        default:
            return .null
        }
    }

    /// Whether a component named a function this client does not implement, so
    /// the renderer can say so instead of drawing a blank.
    static func isKnown(_ name: String) -> Bool {
        knownFunctions.contains(name)
    }

    private static let knownFunctions: Set<String> = [
        "required", "regex", "length", "numeric", "email", "formatString",
        "formatNumber", "formatCurrency", "formatDate", "pluralize", "openUrl",
        "and", "or", "not",
    ]

    // MARK: - formatString

    /// `${/path}` and `${fn(name: literal, other: ${/path})}` interpolation, with
    /// `\${` as the escape for a literal `${`. A small hand-written scanner: the
    /// grammar is tiny, and a real one would still not validate the function
    /// names, which is what actually goes wrong.
    static func interpolate(_ template: String, _ context: A2UIContext, into effects: inout [A2UIEffect]) -> String {
        var output = ""
        var index = template.startIndex
        while index < template.endIndex {
            let character = template[index]
            if character == "\\" {
                let next = template.index(after: index)
                if next < template.endIndex, template[next] == "$" {
                    let afterDollar = template.index(after: next)
                    if afterDollar < template.endIndex, template[afterDollar] == "{" {
                        output.append("${")
                        index = template.index(after: afterDollar)
                        continue
                    }
                }
                output.append(character)
                index = next
                continue
            }
            if character == "$" {
                let next = template.index(after: index)
                if next < template.endIndex, template[next] == "{" {
                    // Find the matching brace, counting nesting so a function
                    // call with an interpolated argument closes at the right one.
                    var depth = 1
                    var cursor = template.index(after: next)
                    var expression = ""
                    while cursor < template.endIndex {
                        let current = template[cursor]
                        if current == "{" { depth += 1 }
                        if current == "}" {
                            depth -= 1
                            if depth == 0 { break }
                        }
                        expression.append(current)
                        cursor = template.index(after: cursor)
                    }
                    if cursor < template.endIndex {
                        output.append(evaluateExpression(expression, context, into: &effects))
                        index = template.index(after: cursor)
                        continue
                    }
                    // Unterminated: keep the text as written rather than
                    // swallowing the rest of the string.
                    output.append("${")
                    index = template.index(after: next)
                    continue
                }
            }
            output.append(character)
            index = template.index(after: index)
        }
        return output
    }

    private static func evaluateExpression(
        _ expression: String,
        _ context: A2UIContext,
        into effects: inout [A2UIEffect]
    ) -> String {
        let trimmed = expression.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        if let open = trimmed.firstIndex(of: "("), trimmed.hasSuffix(")") {
            let name = String(trimmed[trimmed.startIndex..<open]).trimmingCharacters(in: .whitespaces)
            let argumentText = String(trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)])
            let args = parseArguments(argumentText, context, into: &effects)
            return callFunction(name, args: args, context, into: &effects).displayString
        }
        return context.value(trimmed)?.displayString ?? ""
    }

    /// `name: value` pairs, split on commas that are not inside a nested
    /// `${…}`. Values are literals (`'text'`, `"text"`, `12`, `true`) or an
    /// interpolation, which is evaluated.
    private static func parseArguments(
        _ text: String,
        _ context: A2UIContext,
        into effects: inout [A2UIEffect]
    ) -> [String: A2UIValue] {
        var pairs: [String] = []
        var current = ""
        var depth = 0
        for character in text {
            if character == "{" { depth += 1 }
            if character == "}" { depth -= 1 }
            if character == ",", depth == 0 {
                pairs.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { pairs.append(current) }

        var arguments: [String: A2UIValue] = [:]
        for pair in pairs {
            guard let colon = pair.firstIndex(of: ":") else { continue }
            let name = pair[pair.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            let raw = pair[pair.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            arguments[name] = parseLiteral(String(raw), context, into: &effects)
        }
        return arguments
    }

    private static func parseLiteral(
        _ text: String,
        _ context: A2UIContext,
        into effects: inout [A2UIEffect]
    ) -> A2UIValue {
        if text.hasPrefix("${"), text.hasSuffix("}") {
            let inner = String(text.dropFirst(2).dropLast())
            return .string(evaluateExpression(inner, context, into: &effects))
        }
        if text.count >= 2,
           (text.hasPrefix("'") && text.hasSuffix("'")) || (text.hasPrefix("\"") && text.hasSuffix("\"")) {
            return .string(String(text.dropFirst().dropLast()))
        }
        switch text.lowercased() {
        case "true": return .bool(true)
        case "false": return .bool(false)
        case "null": return .null
        default: break
        }
        if let number = Double(text) { return .number(number) }
        return .string(text)
    }

    // MARK: - Formatting helpers

    static func formatNumber(_ value: Double, decimals: Double?, grouping: Bool, currency: String?) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = currency == nil ? .decimal : .currency
        formatter.locale = .current
        if let currency { formatter.currencyCode = currency }
        if let decimals { formatter.minimumFractionDigits = Int(decimals); formatter.maximumFractionDigits = Int(decimals) }
        formatter.usesGroupingSeparator = grouping
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// Parses the ISO 8601 value a `DateTimeInput` stores and formats it with a
    /// TR35 pattern. An unparseable value is returned as written: showing the
    /// raw text is more useful than an empty label.
    static func formatDate(_ value: A2UIValue, pattern: String) -> String {
        let text = value.displayString
        guard !text.isEmpty else { return "" }
        let date = date(fromISO: text)
        guard let date else { return text }
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    static func date(fromISO text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withFullDate]
        if let date = formatter.date(from: text) { return date }
        // A DateTimeInput may hold a time with no date (`09:30`), which ISO
        // 8601 cannot express; read it against today so a label still formats.
        let timeOnly = DateFormatter()
        timeOnly.locale = Locale(identifier: "en_US_POSIX")
        timeOnly.dateFormat = "HH:mm"
        if let clock = timeOnly.date(from: text) {
            let calendar = Calendar.current
            var parts = calendar.dateComponents([.year, .month, .day], from: Date())
            let clockParts = calendar.dateComponents([.hour, .minute], from: clock)
            parts.hour = clockParts.hour
            parts.minute = clockParts.minute
            return calendar.date(from: parts)
        }
        return nil
    }

    /// CLDR plural categories, for the languages this Mac is most likely to run
    /// in. A locale outside the table falls back to `one`/`other`, which is
    /// correct for English and close enough for the rest; the alternative is
    /// shipping a plural-rules database for a label.
    static func pluralize(
        _ count: Double,
        args: [String: A2UIValue],
        _ context: A2UIContext,
        into effects: inout [A2UIEffect]
    ) -> String {
        let category = pluralCategory(count, language: Locale.current.language.languageCode?.identifier ?? "en")
        let order = ["zero", "one", "two", "few", "many", "other"]
        let wanted = [category, "other"]
        for key in wanted {
            if let value = args[key] {
                return string(value, context, into: &effects)
            }
        }
        for key in order where args[key] != nil {
            return string(args[key]!, context, into: &effects)
        }
        return ""
    }

    static func pluralCategory(_ count: Double, language: String) -> String {
        let integer = Int(count.rounded(.towardZero))
        let isInteger = count == Double(integer)
        switch language {
        case "ar":
            if count == 0 { return "zero" }
            if count == 1 { return "one" }
            if count == 2 { return "two" }
            let mod100 = integer % 100
            if (3...10).contains(mod100) { return "few" }
            if (11...99).contains(mod100) { return "many" }
            return "other"
        case "ru", "uk", "pl":
            let mod10 = integer % 10
            let mod100 = integer % 100
            if isInteger, mod10 == 1, mod100 != 11 { return "one" }
            if isInteger, (2...4).contains(mod10), !(12...14).contains(mod100) { return "few" }
            if isInteger, mod10 == 0 || (5...9).contains(mod10) || (11...14).contains(mod100) { return "many" }
            return "other"
        case "fr", "pt":
            return count == 0 || count == 1 ? "one" : "other"
        case "ja", "zh", "ko", "th", "vi":
            return "other"
        default:
            return count == 1 ? "one" : "other"
        }
    }

    /// Deliberately loose: a form's email check exists to catch a typo before
    /// the model sees it, and RFC 5322 validation rejects addresses that work.
    static func isEmail(_ text: String) -> Bool {
        guard !text.contains(" "), text.contains("@"), !text.hasPrefix("@") else { return false }
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        let domain = parts[1]
        guard domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix(".") else { return false }
        return domain.split(separator: ".").allSatisfy { !$0.isEmpty }
    }
}

// MARK: - Checks

extension A2UISurface {
    /// The failure messages of a component's `checks`, in order. A check is
    /// `{condition, message}` in v0.9; the `{call, args, message}` shape from
    /// the specification's prose examples is accepted too, because a model that
    /// read the guide rather than the schema will write that.
    func checkFailures(
        of definition: [String: A2UIValue],
        context: A2UIContext
    ) -> [String] {
        guard let checks = definition["checks"]?.arrayValue else { return [] }
        var failures: [String] = []
        for check in checks {
            guard case .object(let object) = check else { continue }
            let message = object["message"]?.stringValue ?? "That value is not valid."
            var effects: [A2UIEffect] = []
            if let condition = object["condition"] {
                if A2UIFunctions.boolean(condition, context, into: &effects) == true { continue }
            } else if let call = object["call"] {
                let args = object["args"]?.objectValue ?? [:]
                if case .bool(true) = A2UIFunctions.callFunction(call.stringValue ?? "", args: args, context, into: &effects) {
                    continue
                }
            } else {
                continue
            }
            failures.append(message)
        }
        return failures
    }
}
