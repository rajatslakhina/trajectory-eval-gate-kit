//
//  ToolCall.swift
//  TrajectoryEvalGate
//
//  The observed side of the contract: what an agent actually did.
//

/// A JSON-shaped argument value.
///
/// Tool arguments arrive as JSON from every backend worth supporting, so the
/// value model is JSON's, not Swift's. The interesting decision is `Equatable`
/// and `Hashable` conformance, which is written by hand rather than synthesised
/// — see ``ArgumentValue/==(_:_:)``.
public indirect enum ArgumentValue: Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case list([ArgumentValue])
    case object([String: ArgumentValue])
}

extension ArgumentValue: Equatable, Hashable {

    /// Hand-written equality so that two NaN payloads compare equal.
    ///
    /// Synthesised `Equatable` would defer to `Double.==`, under which
    /// `NaN != NaN`. That is correct IEEE-754 arithmetic and completely wrong
    /// for this type: a recorded golden trajectory containing a NaN argument
    /// would never compare equal to itself, so re-running the identical
    /// trajectory would report a diff and fail the gate. A gate that fails on
    /// input it produced itself is worse than no gate.
    ///
    /// Treating all NaNs as one value makes `ArgumentValue` a proper
    /// equivalence relation, which `Hashable` requires and `Set`/`Dictionary`
    /// silently assume.
    public static func == (lhs: ArgumentValue, rhs: ArgumentValue) -> Bool {
        switch (lhs, rhs) {
        case let (.string(a), .string(b)):
            return a == b
        case let (.int(a), .int(b)):
            return a == b
        case let (.double(a), .double(b)):
            if a.isNaN && b.isNaN { return true }
            return a == b
        case let (.bool(a), .bool(b)):
            return a == b
        case (.null, .null):
            return true
        case let (.list(a), .list(b)):
            return a == b
        case let (.object(a), .object(b)):
            return a == b
        default:
            // Deliberately not numeric-coercing: `.int(1)` and `.double(1.0)`
            // are different argument shapes, and a tool schema that accepts
            // both is a schema bug the gate should surface, not hide.
            return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .string(let value):
            hasher.combine(0)
            hasher.combine(value)
        case .int(let value):
            hasher.combine(1)
            hasher.combine(value)
        case .double(let value):
            hasher.combine(2)
            // Canonicalise every NaN bit pattern (and both zeroes) to a single
            // representative so the `==`/`hash` contract holds.
            if value.isNaN {
                hasher.combine(UInt64.max)
            } else if value == 0 {
                hasher.combine(UInt64(0))
            } else {
                hasher.combine(value.bitPattern)
            }
        case .bool(let value):
            hasher.combine(3)
            hasher.combine(value)
        case .null:
            hasher.combine(4)
        case .list(let values):
            hasher.combine(5)
            hasher.combine(values)
        case .object(let values):
            hasher.combine(6)
            // `Dictionary` hashing is already order-independent.
            hasher.combine(values)
        }
    }
}

extension ArgumentValue: CustomStringConvertible {
    public var description: String {
        switch self {
        case .string(let value): return "\"\(value)\""
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .bool(let value): return String(value)
        case .null: return "null"
        case .list(let values): return "[" + values.map(\.description).joined(separator: ", ") + "]"
        case .object(let values):
            let pairs = values.keys.sorted().map { key in
                // Force-unwrap avoided: `values[key]` is non-nil by
                // construction (the key came from `values.keys`), but reading
                // it optionally costs nothing and cannot regress.
                "\(key): \(values[key]?.description ?? "null")"
            }
            return "{" + pairs.joined(separator: ", ") + "}"
        }
    }
}

/// A single tool invocation observed during an agent run.
public struct ToolCall: Sendable, Hashable {
    /// The tool's registered name, e.g. `"lookUpProduct"`.
    public let name: String
    /// Arguments the model supplied, keyed by parameter name.
    public let arguments: [String: ArgumentValue]
    /// Optional backend-assigned identifier, carried through for logs. It is
    /// deliberately *not* part of matching — a golden trajectory must not
    /// depend on a UUID the backend invents at run time.
    public let id: String?

    public init(name: String, arguments: [String: ArgumentValue] = [:], id: String? = nil) {
        self.name = name
        self.arguments = arguments
        self.id = id
    }
}

/// One complete agent run: the ordered tool calls it made and the answer it
/// produced.
public struct Trajectory: Sendable, Hashable {
    public let calls: [ToolCall]
    public let finalAnswer: String?

    public init(calls: [ToolCall], finalAnswer: String? = nil) {
        self.calls = calls
        self.finalAnswer = finalAnswer
    }

    /// Distinct tool names used, in first-use order.
    public var toolNamesUsed: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for call in calls where seen.insert(call.name).inserted {
            ordered.append(call.name)
        }
        return ordered
    }
}
