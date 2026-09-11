//
//  FlakeClassifier.swift
//  TrajectoryEvalGate
//
//  Telling a regression apart from a flake, which is the difference between
//  "revert the PR" and "this case was always unstable and you only noticed now".
//

/// What a sequence of pass/fail outcomes says about a case's stability.
public enum StabilityVerdict: Sendable, Equatable {
    /// Every run passed.
    case stablePassing(runs: Int)
    /// Every run failed. This is the signal that points at the change under
    /// review — a deterministic failure is almost never a sampling artefact.
    case stableFailing(runs: Int)
    /// Mixed outcomes. `lowerBound` is the Wilson lower bound on the pass rate,
    /// so "flaky" carries a number rather than a vibe.
    case flaky(passes: Int, runs: Int, lowerBound: Double)
    /// Fewer runs than the policy's minimum: not enough data to say anything.
    case insufficientData(runs: Int, required: Int)

    public var isStablePassing: Bool {
        if case .stablePassing = self { return true }
        return false
    }

    public var describesInstability: Bool {
        if case .flaky = self { return true }
        return false
    }
}

/// Classifies per-case outcome sequences.
public enum FlakeClassifier {

    /// Classifies a run of outcomes.
    ///
    /// - Parameters:
    ///   - outcomes: `true` for a passing run, in the order they were observed.
    ///   - minimumRuns: below this, the verdict is `insufficientData` rather
    ///     than a confident label. A single passing run is not
    ///     `stablePassing`; calling it that is how a one-sample gate launders
    ///     itself into a green check.
    public static func classify(outcomes: [Bool], minimumRuns: Int, z: Double = Statistics.Z.ninetyFive) -> StabilityVerdict {
        let required = max(1, minimumRuns)
        let runs = outcomes.count
        guard runs >= required else {
            return .insufficientData(runs: runs, required: required)
        }
        let passes = outcomes.reduce(into: 0) { total, passed in
            if passed { total += 1 }
        }
        if passes == runs { return .stablePassing(runs: runs) }
        if passes == 0 { return .stableFailing(runs: runs) }
        return .flaky(
            passes: passes,
            runs: runs,
            lowerBound: Statistics.wilsonLowerBound(successes: passes, trials: runs, z: z)
        )
    }

    /// Alternation rate: the fraction of adjacent run pairs whose outcomes
    /// differ.
    ///
    /// A diagnostic, not a verdict. Two sequences with identical pass rates can
    /// mean different things: `PPPPPFFFFF` (alternation 0.11) looks like
    /// something changed part-way through the sweep — a rate limit kicking in,
    /// a cache warming, a backend deploying mid-run — while `PFPFPFPFPF`
    /// (alternation 1.0) looks like genuine per-run nondeterminism. The first
    /// is worth investigating as an environment problem before it is treated
    /// as model variance.
    ///
    /// - Returns: 0 for fewer than two runs.
    public static func alternationRate(outcomes: [Bool]) -> Double {
        guard outcomes.count >= 2 else { return 0 }
        var changes = 0
        for index in 1..<outcomes.count where outcomes[index] != outcomes[index - 1] {
            changes += 1
        }
        return Saturating.rate(changes, of: outcomes.count - 1)
    }

    /// Whether the current sample differs from a recorded baseline by more than
    /// sampling noise.
    ///
    /// Drift is checked separately from the threshold because the two answer
    /// different questions. The threshold asks "is this good enough to ship";
    /// drift asks "did this change". A case that fell from 99% to 93% still
    /// clears a 90% gate, and is still the most interesting thing in the
    /// report.
    ///
    /// - Returns: `nil` when the comparison is undefined (empty sample, or both
    ///   samples pinned at the same boundary).
    public static func drift(
        current: (passes: Int, runs: Int),
        baseline: (passes: Int, runs: Int),
        criticalZ: Double = Statistics.Z.ninetyFive
    ) -> (z: Double, isSignificant: Bool)? {
        guard let z = Statistics.twoProportionZ(
            successesA: current.passes, trialsA: current.runs,
            successesB: baseline.passes, trialsB: baseline.runs
        ) else { return nil }
        let critical = (criticalZ.isFinite && criticalZ > 0) ? criticalZ : Statistics.Z.ninetyFive
        return (z: z, isSignificant: abs(z) > critical)
    }
}
