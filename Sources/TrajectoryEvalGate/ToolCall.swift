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

extension ArgumentValue {

    /// Hard ceiling on `.list` / `.object` nesting for any value stored in a
    /// ``ToolCall`` or an ``ArgumentMatcher``.
    ///
    /// `==`, `hash(into:)` and `description` all walk this tree recursively.
    /// Tool arguments arrive as JSON from a backend, which makes their *depth*
    /// untrusted input to three recursive functions — and a 100,000-deep list
    /// overflows the stack, which is a crash rather than a catchable error, so
    /// it would take the whole CI job down rather than failing one case. That
    /// is precisely the failure mode this package advertises immunity to.
    ///
    /// The defence is normalisation at the boundary rather than a guard in
    /// each walker: values are depth-limited when they enter a `ToolCall` or an
    /// `ExpectedStep`, so every value the matcher, the differ and the hasher
    /// ever see is provably shallower than this. 64 is far beyond any honest
    /// tool schema and far below any stack limit.
    public static let maximumDepth = 64

    /// Substituted for a subtree that exceeded ``maximumDepth``. Visible in
    /// diffs, so a truncated argument is reported rather than silently altered.
    public static let truncationMarker = "<truncated: exceeded ArgumentValue.maximumDepth>"

    /// Returns a value no deeper than `maxDepth`, replacing anything below
    /// that with ``truncationMarker``.
    ///
    /// The recursion here is bounded by `maxDepth` itself — it stops
    /// descending at the cap rather than at the bottom of the input — so the
    /// sanitiser cannot overflow on the very input it exists to defend
    /// against.
    public func depthLimited(to maxDepth: Int = ArgumentValue.maximumDepth) -> ArgumentValue {
        guard maxDepth > 0 else { return .string(Self.truncationMarker) }
        switch self {
        case .list(let values):
            return .list(values.map { $0.depthLimited(to: maxDepth - 1) })
        case .object(let values):
            return .object(values.mapValues { $0.depthLimited(to: maxDepth - 1) })
        case .string, .int, .double, .bool, .null:
            return self
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

    /// Arguments are depth-limited on the way in — see
    /// ``ArgumentValue/maximumDepth``. This is the boundary at which untrusted
    /// JSON depth stops being able to reach the recursive `==`, `hash(into:)`
    /// and `description` walkers.
    public init(name: String, arguments: [String: ArgumentValue] = [:], id: String? = nil) {
        self.name = name
        self.arguments = arguments.mapValues { $0.depthLimited() }
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
