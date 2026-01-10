import Foundation

struct ImageInfo {
    let range: NSRange
    let path: String
    let width: String?
    let height: String?
    let alt: String?
    let fit: String?
}

struct ImageDetector {
    /// Finds the range of an #image(...) call surrounding the given index.
    static func findImageRange(in text: String, at index: Int) -> NSRange? {
        let nsText = text as NSString
        let pattern = "#image\\s*\\("
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        
        // Safety check: Clamp index
        let safeIndex = max(0, min(index, nsText.length))
        
        for match in matches.reversed() {
            if match.range.location <= safeIndex {
                // Potential start. Now find the matching closing parenthesis.
                if let contentRange = findClosingParenthesis(in: text, startingAt: match.range.location + match.range.length) {
                    let fullRange = NSRange(location: match.range.location, length: contentRange.upperBound - match.range.location)
                    if NSLocationInRange(safeIndex, fullRange) {
                        return fullRange
                    }
                }
            }
        }
        
        return nil
    }
    
    static func parseImage(in text: String, at index: Int) -> ImageInfo? {
        guard let range = findImageRange(in: text, at: index) else { return nil }
        let fullText = (text as NSString).substring(with: range)
        
        // Extract content between parentheses
        guard let startParen = fullText.firstIndex(of: "("),
              let endParen = fullText.lastIndex(of: ")") else { return nil }
        
        let content = String(fullText[fullText.index(after: startParen)..<endParen])
        let parts = smartSplit(content)
        
        var path = ""
        var width: String? = nil
        var height: String? = nil
        var alt: String? = nil
        var fit: String? = nil
        
        for (idx, part) in parts.enumerated() {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if idx == 0 && !trimmed.contains(":") {
                // First positional argument is the path. Strip quotes.
                path = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            } else if trimmed.contains(":") {
                let kv = trimmed.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                if kv.count == 2 {
                    switch kv[0] {
                    case "width": width = kv[1]
                    case "height": height = kv[1]
                    case "alt": alt = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    case "fit": fit = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    default: break
                    }
                }
            }
        }
        
        return ImageInfo(range: range, path: path, width: width, height: height, alt: alt, fit: fit)
    }
    
    private static func findClosingParenthesis(in text: String, startingAt: Int) -> NSRange? {
        let nsText = text as NSString
        var depth = 1
        var index = startingAt
        
        while index < nsText.length {
            let char = nsText.substring(with: NSRange(location: index, length: 1))
            if char == "(" {
                depth += 1
            } else if char == ")" {
                depth -= 1
                if depth == 0 {
                    return NSRange(location: startingAt, length: index - startingAt + 1)
                }
            }
            index += 1
        }
        return nil
    }
    
    private static func smartSplit(_ text: String) -> [String] {
        var parts: [String] = []
        var currentPart = ""
        var depth = 0
        var inQuotes = false
        var escaped = false
        
        for char in text {
            if escaped {
                currentPart.append(char)
                escaped = false
                continue
            }
            if char == "\\" {
                currentPart.append(char)
                escaped = true
                continue
            }
            if char == "\"" {
                inQuotes.toggle()
                currentPart.append(char)
                continue
            }
            if !inQuotes {
                if char == "(" || char == "[" || char == "{" {
                    depth += 1
                } else if char == ")" || char == "]" || char == "}" {
                    depth -= 1
                } else if char == "," && depth == 0 {
                    parts.append(currentPart)
                    currentPart = ""
                    continue
                }
            }
            currentPart.append(char)
        }
        parts.append(currentPart)
        return parts
    }
}
