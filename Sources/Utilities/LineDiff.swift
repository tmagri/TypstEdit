import Foundation

/// A minimal line-based diff used to preview AI Chat file edits before
/// they're written to disk. Plain LCS dynamic programming — fine for the
/// document sizes TypstEdit deals with; callers should fall back to a plain
/// side-by-side view for very large files rather than paying the O(n·m) cost.
enum LineDiff {
    enum Op {
        case equal(String)
        case insert(String)
        case delete(String)
    }

    /// Above this combined line count, skip the DP table and let the caller
    /// fall back to showing old/new in full rather than spending seconds (or
    /// a lot of memory) diffing a huge file.
    static let maxLinesForDiff = 4000

    static func diff(old: String, new: String) -> [Op]? {
        let oldLines = old.components(separatedBy: .newlines)
        let newLines = new.components(separatedBy: .newlines)
        guard oldLines.count + newLines.count <= maxLinesForDiff else { return nil }

        let n = oldLines.count
        let m = newLines.count
        // lcs[i][j] = length of the LCS of oldLines[i...] and newLines[j...]
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                if oldLines[i] == newLines[j] {
                    lcs[i][j] = lcs[i + 1][j + 1] + 1
                } else {
                    lcs[i][j] = max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }

        var ops: [Op] = []
        var i = 0, j = 0
        while i < n && j < m {
            if oldLines[i] == newLines[j] {
                ops.append(.equal(oldLines[i]))
                i += 1; j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                ops.append(.delete(oldLines[i]))
                i += 1
            } else {
                ops.append(.insert(newLines[j]))
                j += 1
            }
        }
        while i < n { ops.append(.delete(oldLines[i])); i += 1 }
        while j < m { ops.append(.insert(newLines[j])); j += 1 }
        return ops
    }
}
