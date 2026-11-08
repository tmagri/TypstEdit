//
//  CaptureNames.swift
//  CodeEditSourceEditor
//
//  Created by Lukas Pistrol on 16.08.22.
//

/// A collection of possible syntax capture types. Represented by an integer for memory efficiency, and with the
/// ability to convert to and from strings for ease of use with tools.
///
/// This is `Int8` raw representable for memory considerations. In large documents there can be *lots* of these created
/// and passed around, so representing them with a single integer is preferable to a string to save memory.
///
public enum CaptureName: Int8, CaseIterable, Sendable {
    case include
    case constructor
    case keyword
    case boolean
    case `repeat`
    case conditional
    case tag
    case comment
    case variable
    case property
    case function
    case method
    case number
    case float
    case string
    case type
    case parameter
    case typeAlternate
    case variableBuiltin
    case keywordReturn
    case keywordFunction
    case textTitle
    case textLiteral
    case textEmphasis
    case textStrong
    case textUri
    case textReference
    case textQuote
    case textList
    case textStrike
    case punctuationSpecial
    case punctuationDelimiter
    case `operator`
    /// Named values and constants (`true`, `false`, `null`, `NSNotFound`).
    /// Python, JSON, YAML and C-family grammars all capture these.
    case constant
    /// Markup attributes: HTML/XML attribute names, CSS property names,
    /// JSON object keys (`@attribute`, `@string.special.key`).
    case attribute
    /// Escape sequences inside strings (`@escape`, `@string.escape`).
    case escape
    /// Preprocessor and annotation markers: `@label`, `@namespace`,
    /// `@media`, `@supports`, `@charset`, `@import`, `@keyframes`.
    case annotation
    /// Text embedded in another language (template interpolations).
    case embedded
    /// Struct/class/object members that are neither plain variables nor
    /// methods (`@field`, `@module`, `@variable.member`).
    case field

    var alternate: CaptureName {
        switch self {
        case .type:
            return .typeAlternate
        default:
            return self
        }
    }

    /// Returns a specific capture name case from a given string.
    /// - Note: See ``CaptureName`` docs for why this enum isn't a raw representable.
    /// - Parameter string: A string to get the capture name from
    /// - Returns: A `CaptureNames` case
    public static func fromString(_ string: String?) -> CaptureName? { // swiftlint:disable:this cyclomatic_complexity
        guard let string else { return nil }
        switch string {
        case "include":
            return .include
        case "constructor":
            return .constructor
        case "keyword":
            return .keyword
        case "boolean":
            return .boolean
        case "repeat":
            return .repeat
        case "conditional":
            return .conditional
        case "tag":
            return .tag
        case "comment":
            return .comment
        case "variable":
            return .variable
        case "property":
            return .property
        case "function":
            return .function
        case "method":
            return .method
        case "number":
            return .number
        case "float":
            return .float
        case "string":
            return .string
        case "type":
            return .type
        case "parameter":
            return .parameter
        case "type_alternate":
            return .typeAlternate
        case "variable.builtin":
            return .variableBuiltin
        case "keyword.return":
            return .keywordReturn
        case "keyword.function":
            return .keywordFunction
        case "text.title":
            return .textTitle
        case "text.literal":
            return .textLiteral
        case "text.emphasis":
            return .textEmphasis
        case "text.strong":
            return .textStrong
        case "text.uri":
            return .textUri
        case "text.reference":
            return .textReference
        case "text.quote":
            return .textQuote
        case "text.list":
            return .textList
        case "text.strike":
            return .textStrike
        case "punctuation.special":
            return .punctuationSpecial
        case "punctuation.delimiter", "punctuation.bracket":
            return .punctuationDelimiter
        case "operator":
            return .`operator`
        // Names used by the bundled Python, JSON, YAML, CSS, HTML and shell
        // queries. Previously they resolved to `nil` and rendered as plain
        // text, which is why JSON keys and HTML attributes looked unstyled.
        case "constant", "constant.macro", "constant.null", "constant.character",
             "constant.builtin":
            return .constant
        case "attribute", "string.special.key", "property.definition", "field":
            return .field
        case "escape", "string.escape", "string.special", "string.regex",
             "string.special.symbol", "character.special":
            return .escape
        case "label", "namespace", "media", "supports", "charset", "import",
             "keyframes", "preproc", "storageclass", "defs", "module":
            return .annotation
        case "embedded":
            return .embedded
        case "variable.member":
            return .property
        case "variable.parameter":
            return .parameter
        case "function.builtin", "function.call", "function.macro",
             "function.method.builtin", "function.special":
            return .function
        case "method.call":
            return .method
        case "type.builtin", "type.qualifier", "type.definition":
            return .type
        default:
            return nil
        }
    }

    /// See ``CaptureName`` docs for why this enum isn't a raw representable.
    var stringValue: String {
        switch self {
        case .include:
            return "include"
        case .constructor:
            return "constructor"
        case .keyword:
            return "keyword"
        case .boolean:
            return "boolean"
        case .repeat:
            return "`repeat`"
        case .conditional:
            return "conditional"
        case .tag:
            return "tag"
        case .comment:
            return "comment"
        case .variable:
            return "variable"
        case .property:
            return "property"
        case .function:
            return "function"
        case .method:
            return "method"
        case .number:
            return "number"
        case .float:
            return "float"
        case .string:
            return "string"
        case .type:
            return "type"
        case .parameter:
            return "parameter"
        case .typeAlternate:
            return "typeAlternate"
        case .variableBuiltin:
            return "variableBuiltin"
        case .keywordReturn:
            return "keywordReturn"
        case .keywordFunction:
            return "keywordFunction"
        case .textTitle:
            return "textTitle"
        case .textLiteral:
            return "textLiteral"
        case .textEmphasis:
            return "textEmphasis"
        case .textStrong:
            return "textStrong"
        case .textUri:
            return "textUri"
        case .textReference:
            return "textReference"
        case .textQuote:
            return "textQuote"
        case .textList:
            return "textList"
        case .textStrike:
            return "textStrike"
        case .punctuationSpecial:
            return "punctuationSpecial"
        case .punctuationDelimiter:
            return "punctuationDelimiter"
        case .`operator`:
            return "operator"
        case .constant:
            return "constant"
        case .attribute:
            return "attribute"
        case .escape:
            return "escape"
        case .annotation:
            return "annotation"
        case .embedded:
            return "embedded"
        case .field:
            return "field"
        }
    }
}

extension CaptureName: CustomDebugStringConvertible {
    public var debugDescription: String { stringValue }
}
