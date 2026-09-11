//
//  GatePolicy.swift
//  TrajectoryEvalGate
//
//  The policy a team writes down once and then argues about in review.
//

/// How many times to run each case, and how confident the gate must be before
/// it turns a build green.
public struct GatePolicy: Sendable, Equatable {

    /// Runs always performed, even if the first one passes. Repeated sampling
    /// is the only defence against a stochastic system that happens to behave.
    public let minimumRuns: Int
    /// Ceiling on runs per case. The gate stops early when the answer can no
    /// longer change (see ``allowsEarlyStop``).
    public let maximumRuns: Int
    /// The bar the *lower confidence bound* on the pass rate must clear.
    ///
    /// Deliberately not "the observed pass rate must clear". See
    /// ``Statistics`` for why 3/3 is not evidence of a 95% pass rate.
    public let requiredPassRateLowerBound: Double
    /// Two-sided critical value for the confidence bound.
    public let confidenceZ: Double
    /// Two-sided critical value for the drift comparison against a baseline.
    public let driftCriticalZ: Double
    /// Whether the gate may stop sampling once the verdict is already decided.
    public let allowsEarlyStop: Bool

    public init(
        minimumRuns: Int,
        maximumRuns: Int,
        requiredPassRateLowerBound: Double,
        confidenceZ: Double = Statistics.Z.ninetyFive,
        driftCriticalZ: Double = Statistics.Z.ninetyFive,
        allowsEarlyStop: Bool = true
    ) {
        let minimum = max(1, minimumRuns)
        self.minimumRuns = minimum
        self.maximumRuns = max(minimum, maximumRuns)
        // A non-finite threshold is a config bug. Clamping NaN to 0 would
        // silently produce a gate that passes everything, so it falls back to a
        // strict-but-sane default instead.
        self.requiredPassRateLowerBound = requiredPassRateLowerBound.isFinite
            ? Saturating.clamp(requiredPassRateLowerBound, to: 0...1)
            : 0.9
        self.confidenceZ = (confidenceZ.isFinite && confidenceZ > 0) ? confidenceZ : Statistics.Z.ninetyFive
        self.driftCriticalZ = (driftCriticalZ.isFinite && driftCriticalZ > 0) ? driftCriticalZ : Statistics.Z.ninetyFive
        self.allowsEarlyStop = allowsEarlyStop
    }

    // MARK: - Presets

    /// 20–60 runs, 90% lower bound. The default for a shipping feature.
    public static let standard = GatePolicy(
        minimumRuns: 20,
        maximumRuns: 60,
        requiredPassRateLowerBound: 0.90
    )

    /// 60–200 runs, 95% lower bound. For a trajectory whose failure has a
    /// side effect (a payment, a delete, an outbound message).
    public static let strict = GatePolicy(
        minimumRuns: 60,
        maximumRuns: 200,
        requiredPassRateLowerBound: 0.95
    )

    /// 5–15 runs, 50% lower bound. For local iteration only; it is honest
    /// about being weak evidence rather than pretending three runs are proof.
    public static let exploratory = GatePolicy(
        minimumRuns: 5,
        maximumRuns: 15,
        requiredPassRateLowerBound: 0.50
    )

    // MARK: - Feasibility

    /// Whether this policy is capable of ever passing.
    public enum Feasibility: Sendable, Equatable {
        case achievable(minimumRunsNeeded: Int)
        /// The threshold cannot be reached even with a perfect run of
        /// `maximumRuns`. `bestPossibleLowerBound` is what a flawless sweep
        /// would actually produce.
        case unachievable(bestPossibleLowerBound: Double, runsNeeded: Int?)

        public var isAchievable: Bool {
            if case .achievable = self { return true }
            return false
        }
    }

    /// Ceiling on the feasibility search, so a threshold of 1.0 (which no
    /// finite sample can ever reach, because the Wilson bound is strictly below
    /// 1 for every finite `n`) terminates instead of looping forever.
    public static let feasibilitySearchCeiling = 100_000

    /// Answers the question almost nobody asks before merging an eval config:
    /// *can this gate pass at all?*
    ///
    /// A 0.95 lower bound needs 73 consecutive passes; a team that
    /// writes `requiredPassRateLowerBound: 0.95, maximumRuns: 10` has built a
    /// gate that is red forever, and will conclude the feature is broken rather
    /// than the policy. Surfacing this as a first-class value — checked in the
    /// demo app and in this package's own tests — turns a silent
    /// misconfiguration into a readable error.
    public var feasibility: Feasibility {
        let bestPossible = Statistics.wilsonLowerBound(
            successes: maximumRuns,
            trials: maximumRuns,
            z: confidenceZ
        )
        if let needed = Self.minimumPerfectRuns(toReach: requiredPassRateLowerBound, z: confidenceZ) {
            if needed <= maximumRuns {
                return .achievable(minimumRunsNeeded: max(needed, minimumRuns))
            }
            return .unachievable(bestPossibleLowerBound: bestPossible, runsNeeded: needed)
        }
        return .unachievable(bestPossibleLowerBound: bestPossible, runsNeeded: nil)
    }

    /// The smallest `n` for which `n` passes out of `n` runs clears
    /// `threshold`, or `nil` if no `n` up to ``feasibilitySearchCeiling`` does.
    ///
    /// The Wilson lower bound for `n/n` is monotonically increasing in `n`,
    /// which is what makes a binary search valid rather than a linear scan.
    public static func minimumPerfectRuns(toReach threshold: Double, z: Double = Statistics.Z.ninetyFive) -> Int? {
        guard threshold.isFinite else { return nil }
        guard threshold > 0 else { return 1 }
        guard Statistics.wilsonLowerBound(successes: feasibilitySearchCeiling, trials: feasibilitySearchCeiling, z: z) >= threshold else {
            return nil
        }
        var low = 1
        var high = feasibilitySearchCeiling
        while low < high {
            // `low + high` cannot overflow: `high` is bounded by the ceiling.
            let mid = (low + high) / 2
            if Statistics.wilsonLowerBound(successes: mid, trials: mid, z: z) >= threshold {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return low
    }

    // MARK: - Sequential decisions

    /// Whether sampling can stop after `trials` runs with `successes` passes.
    ///
    /// Two independent reasons to stop, both saving real money on a metered
    /// backend:
    ///   * the lower bound already clears the threshold, or
    ///   * even a perfect remainder cannot clear it.
    public func shouldStopEarly(successes: Int, trials: Int) -> Bool {
        guard allowsEarlyStop, trials >= minimumRuns, trials < maximumRuns else { return false }
        let achieved = Statistics.wilsonLowerBound(successes: successes, trials: trials, z: confidenceZ)
        if achieved >= requiredPassRateLowerBound { return true }
        let best = Statistics.bestReachableLowerBound(
            successes: successes,
            trialsSoFar: trials,
            maximumTrials: maximumRuns,
            z: confidenceZ
        )
        return best < requiredPassRateLowerBound
    }
}

/// What the gate observed for one case, in enough detail to defend the verdict.
public struct GateEvidence: Sendable, Equatable {
    public let runs: Int
    public let passes: Int
    /// The point estimate. Reported for context; never compared to a threshold.
    public let observedPassRate: Double
    /// The number the verdict is actually made against.
    public let passRateLowerBound: Double
    public let threshold: Double
    public let stoppedEarly: Bool
    /// Drift statistic against a recorded baseline, when one was supplied.
    public let driftZ: Double?

    public init(runs: Int, passes: Int, threshold: Double, z: Double, stoppedEarly: Bool, driftZ: Double? = nil) {
        let clampedRuns = max(0, runs)
        let clampedPasses = Saturating.clamp(passes, to: 0...max(0, clampedRuns))
        self.runs = clampedRuns
        self.passes = clampedPasses
        self.observedPassRate = Saturating.rate(clampedPasses, of: clampedRuns)
        self.passRateLowerBound = Statistics.wilsonLowerBound(successes: clampedPasses, trials: clampedRuns, z: z)
        self.threshold = threshold
        self.stoppedEarly = stoppedEarly
        self.driftZ = driftZ
    }

    public var clearsThreshold: Bool { passRateLowerBound >= threshold }
}

/// The verdict for a single evaluation case.
public enum GateOutcome: Sendable, Equatable {
    case pass
    /// The lower bound did not clear the threshold.
    case fail(reason: String)
    /// The gate could not reach a verdict — budget exhausted before the minimum
    /// run count, or a backend error rate high enough that the sample is not
    /// about the model's behaviour any more.
    ///
    /// Deliberately distinct from `fail`: a build should not be marked broken
    /// because the eval infrastructure ran out of tokens, and it must not be
    /// marked green either.
    case inconclusive(reason: String)

    public var isPass: Bool {
        if case .pass = self { return true }
        return false
    }
}
