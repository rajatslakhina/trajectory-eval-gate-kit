//
//  TrajectoryMatcher.swift
//  TrajectoryEvalGate
//
//  Matching an observed trajectory against a trajectory contract.
//
//  Three orderings, two algorithms, one budget:
//
//  * `.exact` and `.subsequence` are a dynamic program over
//    (step index x call index). A greedy left-to-right walk is wrong the
//    moment a contract contains an optional step, because the walk cannot know
//    whether to spend the current call on the optional step or save it for the
//    required step behind it. The DP considers both.
//
//  * `.unordered` is maximum bipartite matching (Kuhn's augmenting-path
//    algorithm). Greedy assignment is wrong here for the mirror-image reason:
//    a step that could match either of two calls can consume the only call a
//    later, pickier step could have used. Augmenting paths undo that choice.
//    There is a test for exactly this case.
//
//  * Both are bounded. Step and call counts come from a dataset file and from
//    a model that can loop, so the search space is untrusted input. Exceeding
//    the ceiling reports `analysisBudgetExceeded` — a loud, non-passing
//    verdict — rather than hanging the CI job.
//

/// The reasons a trajectory failed its contract.
public struct TrajectoryDiff: Sendable, Equatable {

    /// A contract step no observed call could satisfy.
    public struct UnsatisfiedStep: Sendable, Equatable {
        public let stepIndex: Int
        public let step: ExpectedStep
        /// The call that came closest (same tool name, fewest argument
        /// mismatches), if any call used that tool at all.
        public let closestCallIndex: Int?
        /// Why the closest call failed. Empty when the tool was never called.
        public let mismatches: [ArgumentMismatch]

        public init(stepIndex: Int, step: ExpectedStep, closestCallIndex: Int?, mismatches: [ArgumentMismatch]) {
            self.stepIndex = stepIndex
            self.step = step
            self.closestCallIndex = closestCallIndex
            self.mismatches = mismatches
        }
    }

    public let unsatisfiedSteps: [UnsatisfiedStep]
    /// Indices of calls whose tool name appears in no contract step.
    ///
    /// Diagnostic only. The authoritative verdict is the DP / matching result;
    /// this list exists so a failure message can name the surprising call
    /// instead of saying "the sequence did not match".
    public let unexpectedCallIndices: [Int]
    /// Indices of calls to tools listed in `forbiddenTools`.
    public let forbiddenCallIndices: [Int]
    /// The observed call count, when it exceeded the contract's ceiling.
    public let callCeilingExceededAt: Int?
    /// `true` when the trajectory was too large to analyse within the search
    /// budget. Never treated as a pass.
    public let analysisBudgetExceeded: Bool

    public init(
        unsatisfiedSteps: [UnsatisfiedStep] = [],
        unexpectedCallIndices: [Int] = [],
        forbiddenCallIndices: [Int] = [],
        callCeilingExceededAt: Int? = nil,
        analysisBudgetExceeded: Bool = false
    ) {
        self.unsatisfiedSteps = unsatisfiedSteps
        self.unexpectedCallIndices = unexpectedCallIndices
        self.forbiddenCallIndices = forbiddenCallIndices
        self.callCeilingExceededAt = callCeilingExceededAt
        self.analysisBudgetExceeded = analysisBudgetExceeded
    }

    public var isClean: Bool {
        unsatisfiedSteps.isEmpty
            && forbiddenCallIndices.isEmpty
            && callCeilingExceededAt == nil
            && !analysisBudgetExceeded
    }

    public var summary: String {
        var lines: [String] = []
        if analysisBudgetExceeded {
            lines.append("trajectory too large to analyse within the matcher's search budget")
        }
        if let count = callCeilingExceededAt {
            lines.append("call ceiling exceeded: \(count) calls")
        }
        for index in forbiddenCallIndices {
            lines.append("forbidden tool called at index \(index)")
        }
        for unsatisfied in unsatisfiedSteps {
            if let callIndex = unsatisfied.closestCallIndex {
                let detail = unsatisfied.mismatches.map(\.description).joined(separator: "; ")
                lines.append("step \(unsatisfied.stepIndex) (\(unsatisfied.step.displayName)) unsatisfied; closest call #\(callIndex): \(detail)")
            } else {
                lines.append("step \(unsatisfied.stepIndex) (\(unsatisfied.step.displayName)) unsatisfied; tool `\(unsatisfied.step.toolName)` was never called")
            }
        }
        if !unexpectedCallIndices.isEmpty {
            lines.append("calls at \(unexpectedCallIndices.map(String.init).joined(separator: ", ")) use tools the contract never mentions")
        }
        return lines.isEmpty ? "no differences" : lines.joined(separator: "\n")
    }
}

/// The verdict for one trajectory against one contract.
public enum TrajectoryMatchResult: Sendable, Equatable {
    case matched
    case mismatched(TrajectoryDiff)

    public var didMatch: Bool {
        if case .matched = self { return true }
        return false
    }

    public var diff: TrajectoryDiff? {
        if case .mismatched(let diff) = self { return diff }
        return nil
    }
}

/// Matches observed trajectories against contracts.
public enum TrajectoryMatcher {

    /// Ceiling on DP table cells, i.e. `(steps + 1) * (calls + 1)`.
    ///
    /// 250k cells of `Bool` is a few hundred kilobytes and a few milliseconds —
    /// generous for any honest contract (a 200-step contract against a
    /// 1,000-call run still fits) and small enough that a runaway agent that
    /// emitted 100,000 calls fails fast instead of allocating gigabytes.
    public static let maximumSearchCells = 250_000

    /// Ceiling on steps for `.unordered`, whose augmenting-path search recurses
    /// once per step. Bounded so recursion depth cannot overflow the stack.
    public static let maximumUnorderedSteps = 512

    public static func match(
        _ trajectory: Trajectory,
        against expectation: TrajectoryExpectation
    ) -> TrajectoryMatchResult {

        let calls = trajectory.calls
        let steps = expectation.steps

        // --- Ordering-independent checks -------------------------------------
        // A forbidden tool or a blown call ceiling fails the contract no matter
        // how well the expected steps matched. Both are evaluated first so the
        // diff reports them even when the sequence itself was fine.

        var forbidden: [Int] = []
        if !expectation.forbiddenTools.isEmpty {
            for (index, call) in calls.enumerated() where expectation.forbiddenTools.contains(call.name) {
                forbidden.append(index)
            }
        }

        var ceilingExceededAt: Int?
        if let ceiling = expectation.maximumCalls, calls.count > ceiling {
            ceilingExceededAt = calls.count
        }

        // --- Search budget ----------------------------------------------------

        let cellCount = Saturating.multiply(
            Saturating.add(steps.count, 1),
            Saturating.add(calls.count, 1)
        )
        let overCellBudget = cellCount > maximumSearchCells
        let overStepBudget = expectation.ordering == .unordered && steps.count > maximumUnorderedSteps
        if overCellBudget || overStepBudget {
            return .mismatched(TrajectoryDiff(
                forbiddenCallIndices: forbidden,
                callCeilingExceededAt: ceilingExceededAt,
                analysisBudgetExceeded: true
            ))
        }

        // --- Per-(step, call) match table ------------------------------------
        // Computed once. Both algorithms read it, and so does the diagnostic
        // pass that finds each unsatisfied step's closest call.

        let table = MatchTable(steps: steps, calls: calls)

        let satisfied: Bool
        switch expectation.ordering {
        case .exact:
            satisfied = sequenceMatches(table: table, allowSkippingCalls: false)
        case .subsequence:
            satisfied = sequenceMatches(table: table, allowSkippingCalls: true)
        case .unordered:
            satisfied = unorderedMatches(table: table, steps: steps)
        }

        if satisfied && forbidden.isEmpty && ceilingExceededAt == nil {
            return .matched
        }

        // --- Diagnostics ------------------------------------------------------

        let unsatisfied = satisfied ? [] : diagnose(table: table, steps: steps, calls: calls, ordering: expectation.ordering)
        let contractTools = Set(steps.map(\.toolName))
        let unexpected = satisfied ? [] : calls.indices.filter { !contractTools.contains(calls[$0].name) }

        return .mismatched(TrajectoryDiff(
            unsatisfiedSteps: unsatisfied,
            unexpectedCallIndices: unexpected,
            forbiddenCallIndices: forbidden,
            callCeilingExceededAt: ceilingExceededAt,
            analysisBudgetExceeded: false
        ))
    }

    // MARK: - Match table

    /// A dense `steps x calls` table of "could this step consume this call".
    struct MatchTable {
        let stepCount: Int
        let callCount: Int
        private let cells: [Bool]
        /// Optionality carried alongside the table so the DP does not need the
        /// `steps` array as a second parameter.
        private let optionalFlags: [Bool]
        /// Argument-level mismatches for same-named calls only, used for
        /// diagnostics. Sparse: absent means the tool names differed.
        private let mismatchesByPair: [Int: [ArgumentMismatch]]

        init(steps: [ExpectedStep], calls: [ToolCall]) {
            stepCount = steps.count
            callCount = calls.count
            var cells = [Bool](repeating: false, count: steps.count * calls.count)
            var mismatches: [Int: [ArgumentMismatch]] = [:]
            for stepIndex in steps.indices {
                let step = steps[stepIndex]
                for callIndex in calls.indices {
                    let call = calls[callIndex]
                    guard call.name == step.toolName else { continue }
                    let found = step.mismatches(against: call)
                    let flat = stepIndex * calls.count + callIndex
                    cells[flat] = found.isEmpty
                    mismatches[flat] = found
                }
            }
            self.cells = cells
            self.mismatchesByPair = mismatches
            self.optionalFlags = steps.map(\.isOptional)
        }

        func stepIsOptional(_ index: Int) -> Bool {
            guard index >= 0, index < optionalFlags.count else { return false }
            return optionalFlags[index]
        }

        /// Bounds-checked; out-of-range pairs are simply non-matching rather
        /// than a trap, so a future caller cannot crash the gate with an index
        /// bug.
        func matches(step stepIndex: Int, call callIndex: Int) -> Bool {
            guard stepIndex >= 0, stepIndex < stepCount,
                  callIndex >= 0, callIndex < callCount else { return false }
            return cells[stepIndex * callCount + callIndex]
        }

        /// `nil` when the tool names differ (so there is nothing argument-level
        /// to say); otherwise the argument mismatches, possibly empty.
        func mismatches(step stepIndex: Int, call callIndex: Int) -> [ArgumentMismatch]? {
            guard stepIndex >= 0, stepIndex < stepCount,
                  callIndex >= 0, callIndex < callCount else { return nil }
            return mismatchesByPair[stepIndex * callCount + callIndex]
        }
    }

    // MARK: - Ordered matching (dynamic programming)

    /// `dp[i][j]` = "the first `i` steps can consume the first `j` calls".
    ///
    /// Transitions:
    ///   * skip an optional step:      `dp[i][j] |= dp[i-1][j]`
    ///   * consume call `j` with step `i`: `dp[i][j] |= dp[i-1][j-1] && table[i-1][j-1]`
    ///   * skip an unrelated call (subsequence only): `dp[i][j] |= dp[i][j-1]`
    ///
    /// Under `.exact` the third transition is absent, which is precisely what
    /// makes an extra call a failure.
    static func sequenceMatches(table: MatchTable, allowSkippingCalls: Bool) -> Bool {
        let n = table.stepCount
        let m = table.callCount
        let width = m + 1
        var dp = [Bool](repeating: false, count: (n + 1) * width)
        dp[0] = true

        // Row 0: zero steps. Under `.subsequence` an empty contract tolerates
        // any calls; under `.exact` it tolerates none.
        if allowSkippingCalls && m >= 1 {
            for j in 1...m { dp[j] = true }
        }

        if n >= 1 {
            for i in 1...n {
                let row = i * width
                let previousRow = (i - 1) * width
                let stepIsOptional = table.stepIsOptional(i - 1)
                for j in 0...m {
                    var ok = false
                    if stepIsOptional {
                        ok = dp[previousRow + j]
                    }
                    if !ok, j >= 1, dp[previousRow + (j - 1)], table.matches(step: i - 1, call: j - 1) {
                        ok = true
                    }
                    // Reads `dp[i][j-1]`, already written earlier in this same
                    // ascending `j` loop.
                    if !ok, allowSkippingCalls, j >= 1, dp[row + (j - 1)] {
                        ok = true
                    }
                    dp[row + j] = ok
                }
            }
        }

        return dp[n * width + m]
    }

    // MARK: - Unordered matching (maximum bipartite matching)

    /// Every required step must be assigned a distinct call. Optional steps are
    /// not required to be assigned, so they are simply excluded from the
    /// matching problem — including them could only steal calls from required
    /// steps, which would turn an optional step into a mandatory one.
    static func unorderedMatches(table: MatchTable, steps: [ExpectedStep]) -> Bool {
        let requiredIndices = steps.indices.filter { !steps[$0].isOptional }
        guard !requiredIndices.isEmpty else { return true }
        guard requiredIndices.count <= table.callCount else { return false }

        var callOwner = [Int?](repeating: nil, count: table.callCount)
        for stepIndex in requiredIndices {
            var visited = [Bool](repeating: false, count: table.callCount)
            guard assign(step: stepIndex, table: table, callOwner: &callOwner, visited: &visited) else {
                return false
            }
        }
        return true
    }

    /// One augmenting-path search. Recursion depth is bounded by the number of
    /// required steps, itself bounded by ``maximumUnorderedSteps``.
    private static func assign(
        step stepIndex: Int,
        table: MatchTable,
        callOwner: inout [Int?],
        visited: inout [Bool]
    ) -> Bool {
        guard table.callCount > 0 else { return false }
        for callIndex in 0..<table.callCount {
            guard !visited[callIndex], table.matches(step: stepIndex, call: callIndex) else { continue }
            visited[callIndex] = true
            if let owner = callOwner[callIndex] {
                // The call is taken. Ask its current owner to move.
                if assign(step: owner, table: table, callOwner: &callOwner, visited: &visited) {
                    callOwner[callIndex] = stepIndex
                    return true
                }
            } else {
                callOwner[callIndex] = stepIndex
                return true
            }
        }
        return false
    }

    // MARK: - Diagnostics

    /// Best-effort explanation of *why* a failing trajectory failed.
    ///
    /// This is reporting, not verdict: a step is listed when no observed call
    /// could have satisfied it in isolation. A contract can also fail purely on
    /// ordering, with every step individually satisfiable — in that case this
    /// returns an empty list and the caller's `unexpectedCallIndices` plus the
    /// ordering mode carry the message. Saying nothing is better than inventing
    /// a step-level cause that is not there.
    static func diagnose(
        table: MatchTable,
        steps: [ExpectedStep],
        calls: [ToolCall],
        ordering: OrderingMode
    ) -> [TrajectoryDiff.UnsatisfiedStep] {
        var result: [TrajectoryDiff.UnsatisfiedStep] = []
        for stepIndex in steps.indices {
            let step = steps[stepIndex]
            if step.isOptional { continue }

            var satisfiableBySomeCall = false
            var closestIndex: Int?
            var closestMismatches: [ArgumentMismatch] = []

            for callIndex in calls.indices {
                if table.matches(step: stepIndex, call: callIndex) {
                    satisfiableBySomeCall = true
                    break
                }
                guard let mismatches = table.mismatches(step: stepIndex, call: callIndex) else { continue }
                if closestIndex == nil || mismatches.count < closestMismatches.count {
                    closestIndex = callIndex
                    closestMismatches = mismatches
                }
            }

            guard !satisfiableBySomeCall else { continue }
            result.append(TrajectoryDiff.UnsatisfiedStep(
                stepIndex: stepIndex,
                step: step,
                closestCallIndex: closestIndex,
                mismatches: closestMismatches
            ))
        }
        return result
    }
}
