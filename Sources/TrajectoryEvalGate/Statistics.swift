//
//  Statistics.swift
//  TrajectoryEvalGate
//
//  The small amount of statistics that separates an eval gate from a coin flip.
//
//  The thesis of this package in one file: "3 of 3 runs passed" is not evidence
//  that the feature passes 95% of the time. With n = 3 and s = 3 the Wilson
//  95% lower bound on the true pass rate is about 0.44 — a system that fails
//  more than half the time is entirely consistent with that observation. A gate
//  that reports `pass` there is not measuring anything; it is laundering three
//  samples into a green check.
//
//  So every pass/fail decision in this package is made against a *lower
//  confidence bound* on the pass rate, never against the point estimate. The
//  cost is that a high threshold needs real sample counts, and the budget
//  machinery exists to make that cost visible rather than to hide it.
//

/// Binomial-proportion and two-sample helpers.
///
/// Wilson is used rather than the textbook normal ("Wald") interval because
/// Wald is degenerate exactly where eval gates live: at `s == n` it produces a
/// zero-width interval, so 3/3 would report a lower bound of 1.0 and every gate
/// would pass on three lucky runs. Wilson stays finite and asymmetric at the
/// boundaries, which is the whole reason it is worth the extra algebra.
public enum Statistics {

    /// Common two-sided critical values, exposed so callers do not hardcode
    /// magic numbers in policy files.
    public enum Z {
        /// 90% two-sided.
        public static let ninety = 1.6449
        /// 95% two-sided — the default everywhere in this package.
        public static let ninetyFive = 1.9600
        /// 99% two-sided.
        public static let ninetyNine = 2.5758
    }

    /// The Wilson score interval for a binomial proportion.
    ///
    /// - Parameters:
    ///   - successes: clamped into `0...trials`; a caller that has miscounted
    ///     gets a conservative answer rather than a trap or a nonsense interval.
    ///   - trials: non-positive input yields the maximally uninformative
    ///     `0...1`, which cannot pass any threshold above zero.
    ///   - z: the two-sided critical value; non-finite or negative input falls
    ///     back to 95%.
    public static func wilsonInterval(
        successes: Int,
        trials: Int,
        z: Double = Z.ninetyFive
    ) -> ClosedRange<Double> {
        guard trials > 0 else { return 0...1 }
        let z = (z.isFinite && z > 0) ? z : Z.ninetyFive
        let s = Saturating.clamp(successes, to: 0...trials)
        let n = Double(trials)
        let pHat = Saturating.rate(s, of: trials)

        let zSquared = z * z
        let denominator = 1 + zSquared / n
        let center = pHat + zSquared / (2 * n)
        let varianceTerm = pHat * (1 - pHat) / n + zSquared / (4 * n * n)
        // `varianceTerm` is a sum of non-negative quantities, so it cannot be
        // negative; `max(0,)` guards only against floating-point underflow
        // producing a tiny negative, where `squareRoot()` would return NaN.
        let margin = z * max(0, varianceTerm).squareRoot()

        let lower = Saturating.clamp(Saturating.ratio(center - margin, denominator), to: 0...1)
        let upper = Saturating.clamp(Saturating.ratio(center + margin, denominator, fallback: 1), to: 0...1)
        // Defensive: floating-point error at the extremes could in principle
        // invert the bounds by an ulp, and `ClosedRange` traps on `lower > upper`.
        return lower <= upper ? lower...upper : upper...lower
    }

    /// The lower end of ``wilsonInterval(successes:trials:z:)``.
    ///
    /// This is the number an eval gate should compare against its threshold:
    /// "I am `z`-confident the true pass rate is at least this."
    public static func wilsonLowerBound(
        successes: Int,
        trials: Int,
        z: Double = Z.ninetyFive
    ) -> Double {
        wilsonInterval(successes: successes, trials: trials, z: z).lowerBound
    }

    /// The best pass rate still reachable if every remaining run passes.
    ///
    /// Used for sequential early stopping: once even a perfect run of the
    /// remaining budget cannot clear the threshold, continuing costs money and
    /// changes nothing. Returns the Wilson lower bound of the optimistic
    /// completion.
    public static func bestReachableLowerBound(
        successes: Int,
        trialsSoFar: Int,
        maximumTrials: Int,
        z: Double = Z.ninetyFive
    ) -> Double {
        let total = max(trialsSoFar, maximumTrials)
        let optimisticSuccesses = Saturating.add(successes, Saturating.subtract(total, trialsSoFar))
        return wilsonLowerBound(successes: optimisticSuccesses, trials: total, z: z)
    }

    /// Two-proportion z statistic, for detecting drift between a recorded
    /// baseline and the current run.
    ///
    /// Reported as a statistic against an explicit critical value rather than
    /// as a p-value: a p-value here would need a normal CDF approximation whose
    /// error nobody in the repo would ever check, and the gate only ever asks
    /// the binary question "is this further apart than `criticalZ`".
    ///
    /// - Returns: `nil` when the comparison is undefined — either sample empty,
    ///   or both samples at the same boundary (all-pass vs all-pass, all-fail
    ///   vs all-fail), where the pooled standard error is zero.
    public static func twoProportionZ(
        successesA: Int, trialsA: Int,
        successesB: Int, trialsB: Int
    ) -> Double? {
        guard trialsA > 0, trialsB > 0 else { return nil }
        let sA = Saturating.clamp(successesA, to: 0...trialsA)
        let sB = Saturating.clamp(successesB, to: 0...trialsB)

        let pA = Saturating.rate(sA, of: trialsA)
        let pB = Saturating.rate(sB, of: trialsB)
        let pooled = Saturating.rate(Saturating.add(sA, sB), of: Saturating.add(trialsA, trialsB))

        let varianceTerm = pooled * (1 - pooled) * (1 / Double(trialsA) + 1 / Double(trialsB))
        guard varianceTerm > 0 else { return nil }
        let standardError = varianceTerm.squareRoot()
        guard standardError > 0 else { return nil }

        let z = (pA - pB) / standardError
        return z.isFinite ? z : nil
    }
}
