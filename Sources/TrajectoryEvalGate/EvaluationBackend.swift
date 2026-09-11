//
//  EvaluationBackend.swift
//  TrajectoryEvalGate
//
//  The seam between this package and whatever actually runs the agent.
//
//  Everything else in this package is pure value types and arithmetic, and that
//  is not an accident. The gate's logic — trajectory matching, confidence
//  bounds, flake classification, judge calibration, budgets — is the part a
//  team has to reason about, review, and unit-test on every platform including
//  Linux CI. Binding that logic to a specific inference framework would make
//  all of it untestable without a device.
//
//  So the framework lives behind one protocol with one method. Concretely:
//
//    * On Apple platforms, an adapter conforms by driving Apple's Evaluations
//      framework (`Evaluation`, `ToolCallEvaluator`, `TrajectoryExpectation`)
//      against Foundation Models — on-device or Private Cloud Compute — and
//      translating its result into a ``Trajectory``.
//    * A remote model behind an HTTP API conforms by parsing tool-call blocks
//      out of the response.
//    * ``DeterministicBackend`` conforms with a seeded PRNG, which is what the
//      tests and the demo app use.
//
//  The gate cannot tell them apart, which is the point: the same policy, the
//  same thresholds, and the same report apply whether the model is on the
//  device or across the network.
//

/// One evaluation case: a prompt, the trajectory contract it must satisfy, and
/// optionally what this case scored last time.
public struct EvalCase: Sendable, Equatable, Identifiable {
    public let id: String
    /// What the agent is asked to do.
    public let prompt: String
    /// The contract its tool calls must satisfy.
    public let expectation: TrajectoryExpectation
    /// A recorded result from a previous sweep, used for drift detection.
    public let baseline: BaselineRecord?

    public init(id: String, prompt: String, expectation: TrajectoryExpectation, baseline: BaselineRecord? = nil) {
        self.id = id
        self.prompt = prompt
        self.expectation = expectation
        self.baseline = baseline
    }
}

/// A previous sweep's result for one case.
public struct BaselineRecord: Sendable, Equatable {
    public let passes: Int
    public let runs: Int

    public init(passes: Int, runs: Int) {
        let clampedRuns = max(0, runs)
        self.runs = clampedRuns
        self.passes = Saturating.clamp(passes, to: 0...max(0, clampedRuns))
    }
}

/// What one agent run produced.
public struct BackendRunResult: Sendable, Equatable {
    /// The tool calls the agent made, in order.
    public let trajectory: Trajectory
    /// Tokens consumed, for the budget ledger. Clamped at zero.
    public let tokensUsed: Int
    /// A model-as-judge quality score in `0...1`, when the backend ran a judge.
    ///
    /// Note that a judged score only participates in the verdict if the judge
    /// has been calibrated — see ``JudgeCalibration``. An uncalibrated judge is
    /// carried in the report as information, never as a gate.
    public let judgeScore: Double?

    public init(trajectory: Trajectory, tokensUsed: Int = 0, judgeScore: Double? = nil) {
        self.trajectory = trajectory
        self.tokensUsed = max(0, tokensUsed)
        self.judgeScore = judgeScore.map { Saturating.clamp($0, to: 0...1) }
    }
}

/// Anything that can run an agent once and report what it did.
public protocol EvaluationBackend: Sendable {
    /// Stable name for the report, e.g. `"foundation-models-on-device"`.
    var identifier: String { get }

    /// Runs `evalCase` once.
    ///
    /// - Parameter attempt: zero-based repetition index. Backends that want
    ///   reproducibility derive their seed from it; backends talking to a real
    ///   model ignore it.
    /// - Throws: infrastructure failures only. A run that completes but does
    ///   the wrong thing is *not* an error — it is a failing run, and the
    ///   difference is what keeps a flaky network from reading as a broken
    ///   model.
    func run(_ evalCase: EvalCase, attempt: Int) async throws -> BackendRunResult
}

/// Spending limits for a sweep.
public struct EvalBudget: Sendable, Equatable {
    /// Hard ceiling on backend invocations across all cases.
    public let maximumRuns: Int
    /// Hard ceiling on tokens across all cases. `nil` means untracked.
    public let maximumTokens: Int?

    public init(maximumRuns: Int, maximumTokens: Int? = nil) {
        self.maximumRuns = max(0, maximumRuns)
        self.maximumTokens = maximumTokens.map { max(0, $0) }
    }

    /// Derives a budget that can actually complete the policy for `caseCount`
    /// cases, so a sweep is not cut off mid-case by a number someone guessed.
    ///
    /// A budget smaller than `caseCount * policy.minimumRuns` guarantees at
    /// least one case ends `inconclusive`. Making that arithmetic explicit —
    /// and exposing ``isSufficient(for:caseCount:)`` — is the difference
    /// between a gate that reports "ran out of budget" and one that quietly
    /// reports fewer cases than it was given.
    public static func sufficient(for policy: GatePolicy, caseCount: Int, tokensPerRun: Int? = nil) -> EvalBudget {
        let runs = Saturating.multiply(max(0, caseCount), policy.maximumRuns)
        let tokens = tokensPerRun.map { Saturating.multiply(runs, max(0, $0)) }
        return EvalBudget(maximumRuns: runs, maximumTokens: tokens)
    }

    /// Whether this budget can fund the policy's *minimum* sampling for every
    /// case. A `false` here means at least one case is guaranteed to come back
    /// `inconclusive`.
    public func isSufficient(for policy: GatePolicy, caseCount: Int) -> Bool {
        maximumRuns >= Saturating.multiply(max(0, caseCount), policy.minimumRuns)
    }
}

/// Errors a backend may surface. Provided for convenience; backends are free to
/// throw their own.
public enum EvaluationBackendError: Error, Sendable, Equatable {
    case transport(String)
    case modelUnavailable(String)
    case malformedResponse(String)
}
