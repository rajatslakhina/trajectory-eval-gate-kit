//
//  EvalGateRunner.swift
//  TrajectoryEvalGate
//
//  The orchestration layer: sample each case until the verdict stops changing,
//  spend no more than the budget, and report enough to defend the result.
//

/// The result for one evaluation case.
public struct CaseResult: Sendable, Equatable, Identifiable {
    public let id: String
    public let outcome: GateOutcome
    public let evidence: GateEvidence
    public let stability: StabilityVerdict
    /// Fraction of adjacent run pairs whose outcomes differed. See
    /// ``FlakeClassifier/alternationRate(outcomes:)``.
    public let alternationRate: Double
    /// `true` when the case moved significantly against its recorded baseline,
    /// `nil` when no baseline existed or the comparison was undefined.
    public let driftIsSignificant: Bool?
    /// The first failing run's diff, kept so the report can show *why* without
    /// storing every trajectory.
    public let representativeDiff: TrajectoryDiff?
    /// Runs that threw instead of completing. Infrastructure, not model quality.
    public let errorCount: Int

    public init(
        id: String,
        outcome: GateOutcome,
        evidence: GateEvidence,
        stability: StabilityVerdict,
        alternationRate: Double,
        driftIsSignificant: Bool?,
        representativeDiff: TrajectoryDiff?,
        errorCount: Int
    ) {
        self.id = id
        self.outcome = outcome
        self.evidence = evidence
        self.stability = stability
        self.alternationRate = alternationRate
        self.driftIsSignificant = driftIsSignificant
        self.representativeDiff = representativeDiff
        self.errorCount = max(0, errorCount)
    }
}

/// The whole sweep.
public struct GateReport: Sendable, Equatable {
    public let backendIdentifier: String
    public let policy: GatePolicy
    public let results: [CaseResult]
    public let runsSpent: Int
    public let tokensSpent: Int
    /// `true` when sampling stopped because the budget ran out rather than
    /// because the verdicts were settled.
    public let budgetExhausted: Bool

    public init(
        backendIdentifier: String,
        policy: GatePolicy,
        results: [CaseResult],
        runsSpent: Int,
        tokensSpent: Int,
        budgetExhausted: Bool
    ) {
        self.backendIdentifier = backendIdentifier
        self.policy = policy
        self.results = results
        self.runsSpent = max(0, runsSpent)
        self.tokensSpent = max(0, tokensSpent)
        self.budgetExhausted = budgetExhausted
    }

    /// Whether CI should go green.
    ///
    /// An empty sweep is **not** green. A report with no cases means the
    /// dataset failed to load or every case was filtered out, and the single
    /// most common way an eval gate becomes decorative is by silently
    /// evaluating nothing and passing.
    public var isGreen: Bool {
        !results.isEmpty && results.allSatisfy { $0.outcome.isPass }
    }

    public var failingCases: [CaseResult] {
        results.filter { if case .fail = $0.outcome { return true } else { return false } }
    }

    public var inconclusiveCases: [CaseResult] {
        results.filter { if case .inconclusive = $0.outcome { return true } else { return false } }
    }

    public var flakyCases: [CaseResult] {
        results.filter { $0.stability.describesInstability }
    }

    public var driftedCases: [CaseResult] {
        results.filter { $0.driftIsSignificant == true }
    }

    /// One-line CI summary.
    public var headline: String {
        guard !results.isEmpty else {
            return "EVAL GATE: no cases evaluated — treated as a failure, not a pass"
        }
        let verdict = isGreen ? "PASS" : "FAIL"
        var parts = ["EVAL GATE \(verdict): \(results.count - failingCases.count - inconclusiveCases.count)/\(results.count) cases cleared"]
        if !failingCases.isEmpty { parts.append("\(failingCases.count) failing") }
        if !inconclusiveCases.isEmpty { parts.append("\(inconclusiveCases.count) inconclusive") }
        if !flakyCases.isEmpty { parts.append("\(flakyCases.count) flaky") }
        if !driftedCases.isEmpty { parts.append("\(driftedCases.count) drifted") }
        parts.append("\(runsSpent) runs")
        if budgetExhausted { parts.append("budget exhausted") }
        return parts.joined(separator: " · ")
    }
}

/// Runs a sweep against a backend, under a budget.
///
/// ### Why an actor, and what that does and does not buy
///
/// The budget ledger is mutable state shared across every case in a sweep and
/// across any concurrent sweeps that share this runner, so it needs isolation.
/// Actor isolation alone is *not* enough: `evaluate` suspends at every
/// `await backend.run(...)`, and another task can enter the actor during that
/// suspension. A naive `if runsSpent < limit { await run(); runsSpent += 1 }`
/// would let N concurrent sweeps each read the same pre-increment value and
/// overspend by N runs — the classic actor-reentrancy bug, and an expensive one
/// when each run is a billed model call.
///
/// The fix is that **no read-modify-write of the ledger spans a suspension
/// point**. ``reserveRun()`` checks and decrements in one synchronous,
/// actor-isolated body, so a run is paid for before it starts. Token spend is
/// settled after the fact because the cost is not known in advance; the
/// documented consequence is that a sweep may overshoot its token ceiling by at
/// most one run, and the ceiling is checked again before the next reservation.
public actor EvalGateRunner {

    private let backend: EvaluationBackend
    private let budget: EvalBudget
    private var runsSpent = 0
    private var tokensSpent = 0

    public init(backend: EvaluationBackend, budget: EvalBudget) {
        self.backend = backend
        self.budget = budget
    }

    public var spentRuns: Int { runsSpent }
    public var spentTokens: Int { tokensSpent }

    /// Atomically reserves one run against the budget.
    ///
    /// Synchronous by construction — adding an `await` anywhere in this body
    /// would reintroduce the double-spend it exists to prevent.
    private func reserveRun() -> Bool {
        guard runsSpent < budget.maximumRuns else { return false }
        runsSpent = Saturating.add(runsSpent, 1)
        return true
    }

    private func settle(tokens: Int) {
        tokensSpent = Saturating.add(tokensSpent, max(0, tokens))
    }

    private func tokenBudgetExhausted() -> Bool {
        guard let ceiling = budget.maximumTokens else { return false }
        return tokensSpent >= ceiling
    }

    /// Samples every case until its verdict is settled, the per-case ceiling is
    /// reached, or the budget runs out.
    public func evaluate(cases: [EvalCase], policy: GatePolicy) async -> GateReport {
        var results: [CaseResult] = []
        var budgetExhausted = false

        for evalCase in cases {
            var outcomes: [Bool] = []
            var errorCount = 0
            var representativeDiff: TrajectoryDiff?
            var stoppedEarly = false

            // Errors count against the per-case attempt ceiling as well as
            // successes. Without that, a backend that throws every time would
            // loop forever against `outcomes.count < maximumRuns`.
            while Saturating.add(outcomes.count, errorCount) < policy.maximumRuns {
                guard reserveRun() else {
                    budgetExhausted = true
                    break
                }
                do {
                    let attempt = Saturating.add(outcomes.count, errorCount)
                    let runResult = try await backend.run(evalCase, attempt: attempt)
                    settle(tokens: runResult.tokensUsed)
                    let match = TrajectoryMatcher.match(runResult.trajectory, against: evalCase.expectation)
                    outcomes.append(match.didMatch)
                    if representativeDiff == nil, let diff = match.diff {
                        representativeDiff = diff
                    }
                } catch {
                    errorCount += 1
                }

                if tokenBudgetExhausted() {
                    budgetExhausted = true
                    break
                }
                let passes = passCount(outcomes)
                if policy.shouldStopEarly(successes: passes, trials: outcomes.count) {
                    stoppedEarly = true
                    break
                }
            }

            results.append(makeResult(
                for: evalCase,
                outcomes: outcomes,
                errorCount: errorCount,
                stoppedEarly: stoppedEarly,
                representativeDiff: representativeDiff,
                policy: policy
            ))
        }

        return GateReport(
            backendIdentifier: backend.identifier,
            policy: policy,
            results: results,
            runsSpent: runsSpent,
            tokensSpent: tokensSpent,
            budgetExhausted: budgetExhausted
        )
    }

    private func passCount(_ outcomes: [Bool]) -> Int {
        outcomes.reduce(into: 0) { total, passed in
            if passed { total += 1 }
        }
    }

    private func makeResult(
        for evalCase: EvalCase,
        outcomes: [Bool],
        errorCount: Int,
        stoppedEarly: Bool,
        representativeDiff: TrajectoryDiff?,
        policy: GatePolicy
    ) -> CaseResult {
        let passes = passCount(outcomes)
        let stability = FlakeClassifier.classify(outcomes: outcomes, minimumRuns: policy.minimumRuns, z: policy.confidenceZ)
        let alternation = FlakeClassifier.alternationRate(outcomes: outcomes)

        var driftZ: Double?
        var driftSignificant: Bool?
        if let baseline = evalCase.baseline,
           let drift = FlakeClassifier.drift(
                current: (passes: passes, runs: outcomes.count),
                baseline: (passes: baseline.passes, runs: baseline.runs),
                criticalZ: policy.driftCriticalZ
           ) {
            driftZ = drift.z
            driftSignificant = drift.isSignificant
        }

        let evidence = GateEvidence(
            runs: outcomes.count,
            passes: passes,
            threshold: policy.requiredPassRateLowerBound,
            z: policy.confidenceZ,
            stoppedEarly: stoppedEarly,
            driftZ: driftZ
        )

        let outcome = decide(evidence: evidence, errorCount: errorCount, policy: policy)

        return CaseResult(
            id: evalCase.id,
            outcome: outcome,
            evidence: evidence,
            stability: stability,
            alternationRate: alternation,
            driftIsSignificant: driftSignificant,
            representativeDiff: representativeDiff,
            errorCount: errorCount
        )
    }

    /// The verdict rule, isolated so it can be read in one screen and argued
    /// about in review.
    ///
    /// Order matters. Infrastructure problems are checked *before* quality,
    /// because a sample dominated by transport errors is not a measurement of
    /// the model — reporting it as `fail` would send someone to debug a prompt
    /// when the real problem is a proxy.
    private func decide(evidence: GateEvidence, errorCount: Int, policy: GatePolicy) -> GateOutcome {
        if evidence.runs < policy.minimumRuns {
            return .inconclusive(reason: "only \(evidence.runs) completed run(s); policy requires \(policy.minimumRuns)"
                + (errorCount > 0 ? " (\(errorCount) run(s) errored)" : " (budget exhausted)"))
        }
        if errorCount > evidence.runs {
            return .inconclusive(reason: "\(errorCount) errored run(s) against \(evidence.runs) completed; the sample reflects infrastructure, not model behaviour")
        }
        guard evidence.clearsThreshold else {
            let bound = (evidence.passRateLowerBound * 1000).rounded() / 1000
            let observed = (evidence.observedPassRate * 1000).rounded() / 1000
            return .fail(reason: "\(evidence.passes)/\(evidence.runs) passed (rate \(observed)); "
                + "pass-rate lower bound \(bound) is below the required \(policy.requiredPassRateLowerBound)")
        }
        return .pass
    }
}
