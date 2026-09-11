//
//  TrajectoryExpectation.swift
//  TrajectoryEvalGate
//
//  The trajectory contract: what the agent was supposed to do.
//

/// One expected tool invocation in a trajectory contract.
public struct ExpectedStep: Sendable, Equatable {
    /// The tool that must be called.
    public let toolName: String
    /// Per-argument predicates. Keys not listed here are unconstrained, so a
    /// contract does not break when a tool gains an optional parameter.
    public let arguments: [String: ArgumentMatcher]
    /// When `true`, the trajectory still matches if this step never happens.
    ///
    /// Optional steps are the reason matching needs dynamic programming rather
    /// than a zip: a greedy left-to-right walk cannot know whether to spend the
    /// current call on an optional step or save it for the required step that
    /// follows.
    public let isOptional: Bool
    /// Human-readable label used in diffs and in the demo UI.
    public let label: String?

    public init(
        toolName: String,
        arguments: [String: ArgumentMatcher] = [:],
        isOptional: Bool = false,
        label: String? = nil
    ) {
        self.toolName = toolName
        self.arguments = arguments
        self.isOptional = isOptional
        self.label = label
    }

    public var displayName: String { label ?? toolName }

    /// Evaluates this step against one observed call.
    ///
    /// - Returns: an empty array on a match, otherwise every argument-level
    ///   reason it failed. Returning *all* reasons rather than the first is
    ///   deliberate: a developer reading a CI failure should not have to
    ///   re-run to discover the second broken argument.
    public func mismatches(against call: ToolCall) -> [ArgumentMismatch] {
        guard call.name == toolName else {
            return [ArgumentMismatch(
                key: "<tool>",
                matcher: .equals(.string(toolName)),
                actual: .string(call.name),
                reason: "expected tool `\(toolName)`"
            )]
        }
        var found: [ArgumentMismatch] = []
        // Sorted for determinism: dictionary iteration order is not stable
        // across processes, and a diff that reorders itself between CI runs
        // cannot be compared to the previous run's diff.
        for key in arguments.keys.sorted() {
            guard let matcher = arguments[key] else { continue }
            if let mismatch = matcher.evaluate(key: key, value: call.arguments[key]) {
                found.append(mismatch)
            }
        }
        return found
    }

    public func matches(_ call: ToolCall) -> Bool {
        mismatches(against: call).isEmpty
    }
}

/// How strictly the observed call sequence must follow the expected steps.
public enum OrderingMode: String, Sendable, CaseIterable {
    /// Every observed call must be consumed by a step, in order. Extra calls
    /// are a failure. Use for trajectories where an extra tool call is itself
    /// the regression (cost, latency, side effects).
    case exact
    /// Steps must appear in order, but unrelated calls may appear between them.
    /// The common default: it pins causality without pinning chattiness.
    case subsequence
    /// Steps must all be satisfied by distinct calls, in any order. Use when
    /// the agent may legitimately parallelise independent lookups.
    case unordered
}

/// A complete trajectory contract for one evaluation case.
public struct TrajectoryExpectation: Sendable, Equatable {
    public let steps: [ExpectedStep]
    public let ordering: OrderingMode
    /// Tools that must never be called. Checked independently of ordering —
    /// a destructive tool appearing anywhere is a failure even if every
    /// expected step matched.
    public let forbiddenTools: Set<String>
    /// Optional ceiling on total calls, as a cost/loop guard. `nil` means no
    /// ceiling.
    public let maximumCalls: Int?

    public init(
        steps: [ExpectedStep],
        ordering: OrderingMode = .subsequence,
        forbiddenTools: Set<String> = [],
        maximumCalls: Int? = nil
    ) {
        self.steps = steps
        self.ordering = ordering
        self.forbiddenTools = forbiddenTools
        // A negative or zero ceiling is a dataset typo, not an intent to forbid
        // all tool use; normalising it to `nil` avoids a contract that can
        // never pass and that nobody would notice was never passing.
        self.maximumCalls = maximumCalls.flatMap { $0 > 0 ? $0 : nil }
    }

    /// Steps that must be satisfied for the contract to hold.
    public var requiredSteps: [ExpectedStep] { steps.filter { !$0.isOptional } }
}
