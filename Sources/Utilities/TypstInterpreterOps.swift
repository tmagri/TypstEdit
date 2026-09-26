import Foundation

// MARK: - TypstInterpreterOps.swift
// Binary/unary operator evaluation. Semantics per the reference (ops.rs):
// `and`/`or` short-circuit and require bools; `/` promotes to float; `+` joins
// strings/arrays/dicts/content; comparisons work across int/float/quantity/str.

extension TypstInterpreter {

    func evalBinary(op: TypstBinOp, lhs: TypstExpr, rhs: TypstExpr) throws -> TypstValue {
        // Short-circuit (reference ops.rs:66-71).
        if op == .and {
            guard case .bool(let l) = try eval(expr: lhs) else {
                throw TypstEvalError("expected boolean")
            }
            if !l { return .bool(false) }
            guard case .bool(let r) = try eval(expr: rhs) else {
                throw TypstEvalError("expected boolean")
            }
            return .bool(r)
        }
        if op == .or {
            guard case .bool(let l) = try eval(expr: lhs) else {
                throw TypstEvalError("expected boolean")
            }
            if l { return .bool(true) }
            guard case .bool(let r) = try eval(expr: rhs) else {
                throw TypstEvalError("expected boolean")
            }
            return .bool(r)
        }

        let left = try eval(expr: lhs)
        let right = try eval(expr: rhs)
        return try applyBinary(op: op, lhs: left, rhs: right)
    }

    func applyBinary(op: TypstBinOp, lhs: TypstValue, rhs: TypstValue) throws -> TypstValue {
        switch op {
        case .eq: return .bool(lhs == rhs)
        case .neq: return .bool(lhs != rhs)
        case .lt, .leq, .gt, .geq:
            return .bool(try compare(op: op, lhs: lhs, rhs: rhs))
        case .inOp, .notIn:
            let contained: Bool
            switch (lhs, rhs) {
            case (.str(let needle), .str(let haystack)):
                contained = haystack.contains(needle)
            case (_, .array(let items)):
                contained = items.contains { $0 == lhs }
            case (.str(let key), .dict(let dict)):
                contained = dict[key] != nil
            default:
                throw TypstEvalError("cannot apply 'in' to \(lhs.typeName) and \(rhs.typeName)")
            }
            return .bool(op == .inOp ? contained : !contained)
        case .and, .or:
            // Strict form (reached via augmented assignment path only).
            guard case .bool(let l) = lhs, case .bool(let r) = rhs else {
                throw TypstEvalError("expected boolean")
            }
            return .bool(op == .and ? l && r : l || r)
        case .add:
            return try addValues(lhs, rhs)
        case .sub, .mul, .div:
            return try arithmetic(op: op, lhs: lhs, rhs: rhs)
        default:
            throw TypstEvalError("invalid binary operator")
        }
    }

    private func compare(op: TypstBinOp, lhs: TypstValue, rhs: TypstValue) throws -> Bool {
        func asNumber(_ value: TypstValue) throws -> Double {
            switch value {
            case .int(let i): return Double(i)
            case .float(let f): return f
            case .quantity(let q, _): return q
            case .str(let s): return Double(s) ?? 0
            default:
                throw TypstEvalError("cannot compare \(value.typeName) values")
            }
        }
        // String-to-string comparison is lexicographic.
        if case .str(let a) = lhs, case .str(let b) = rhs {
            switch op {
            case .lt: return a < b
            case .leq: return a <= b
            case .gt: return a > b
            case .geq: return a >= b
            default: return false
            }
        }
        let l = try asNumber(lhs)
        let r = try asNumber(rhs)
        switch op {
        case .lt: return l < r
        case .leq: return l <= r
        case .gt: return l > r
        case .geq: return l >= r
        default: return false
        }
    }

    private func addValues(_ lhs: TypstValue, _ rhs: TypstValue) throws -> TypstValue {
        switch (lhs, rhs) {
        case (.int(let a), .int(let b)): return .int(a &+ b)
        case (.float(let a), .float(let b)): return .float(a + b)
        case (.int(let a), .float(let b)): return .float(Double(a) + b)
        case (.float(let a), .int(let b)): return .float(a + Double(b))
        case (.quantity(let a, let ua), .quantity(let b, _)):
            // Different-unit sums (`0.5pt + 1cm`) have no Markdown meaning; keep
            // the left unit rather than leaking the enclosing call.
            return .quantity(a + b, unit: ua)
        case (.str(let a), .str(let b)): return .str(a + b)
        case (.array(let a), .array(let b)): return .array(a + b)
        case (.dict(let a), .dict(let b)):
            var merged = a
            for (key, value) in b.entries { merged.set(key, value) }
            return .dict(merged)
        case (.content(let a), .content(let b)):
            return .content(TypstValue.joinContent(a, b))
        case (.content(let a), .str(let b)):
            return .content(TypstValue.joinContent(a, .text(b)))
        case (.str(let a), .content(let b)):
            return .content(TypstValue.joinContent(.text(a), b))
        case (.str(let a), .int(let b)): return .str(a + String(b))
        case (.str(let a), .float(let b)): return .str(a + TypstValue.displayFloat(b))
        // Styling sums (`stroke: 0.5pt + black`, `2em + red`, `1fr + black`)
        // never render — the renderer drops those named arguments — so degrade
        // to a string instead of throwing and leaking the whole enclosing call.
        case (.quantity(let a, let ua), .str(let b)):
            return .str(TypstValue.displayFloat(a) + ua + b)
        case (.str(let a), .quantity(let b, let ub)):
            return .str(a + TypstValue.displayFloat(b) + ub)
        case (.quantity(let a, let ua), .none):
            return .str(TypstValue.displayFloat(a) + ua)
        case (.none, .quantity(let b, let ub)):
            return .str(TypstValue.displayFloat(b) + ub)
        default:
            throw TypstEvalError("cannot add \(lhs.typeName) and \(rhs.typeName)")
        }
    }

    private func arithmetic(op: TypstBinOp, lhs: TypstValue, rhs: TypstValue) throws -> TypstValue {
        // Same-unit quantities subtract/multiply/divide as plain numbers.
        switch (lhs, rhs) {
        case (.int(let a), .int(let b)):
            switch op {
            case .sub: return .int(a &- b)
            case .mul: return .int(a &* b)
            case .div:
                guard b != 0 else { throw TypstEvalError("division by zero") }
                return .float(Double(a) / Double(b))
            default: break
            }
        case (.quantity(let a, let ua), .quantity(let b, let ub)) where ua == ub:
            let value: Double
            switch op {
            case .sub: value = a - b
            case .mul: value = a * b
            case .div: value = b == 0 ? Double.infinity : a / b
            default: value = 0
            }
            return .quantity(value, unit: ua)
        default:
            break
        }

        func asNumber(_ value: TypstValue) throws -> Double {
            switch value {
            case .int(let i): return Double(i)
            case .float(let f): return f
            case .quantity(let q, _): return q
            default:
                throw TypstEvalError("cannot apply operator to \(lhs.typeName) and \(rhs.typeName)")
            }
        }
        let l = try asNumber(lhs)
        let r = try asNumber(rhs)
        switch op {
        case .sub: return .float(l - r)
        case .mul: return .float(l * r)
        case .div:
            guard r != 0 else { throw TypstEvalError("division by zero") }
            return .float(l / r)
        default:
            throw TypstEvalError("invalid operator")
        }
    }

    func evalUnary(op: TypstUnOp, operand: TypstExpr) throws -> TypstValue {
        let value = try eval(expr: operand)
        switch op {
        case .neg:
            switch value {
            case .int(let i): return .int(-i)
            case .float(let f): return .float(-f)
            case .quantity(let q, let unit): return .quantity(-q, unit: unit)
            default:
                throw TypstEvalError("cannot negate \(value.typeName)")
            }
        case .pos:
            return value
        case .not:
            guard case .bool(let b) = value else {
                throw TypstEvalError("expected boolean, found \(value.typeName)")
            }
            return .bool(!b)
        }
    }
}
