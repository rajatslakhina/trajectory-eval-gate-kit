import XCTest
@testable import TrajectoryEvalGate

/// The statistics that make this a gate rather than a coin flip.
///
/// The expected values here were computed out-of-band from the Wilson score
/// formula, not by calling the implementation — a test that computes its own
/// expectation with the same code it is testing asserts only that the code is
/// deterministic.
final class StatisticsTests: XCTestCase {

    // MARK: - Wilson bounds against precomputed values

    func testWilsonLowerBoundMatchesPrecomputedValues() {
        XCTAssertEqual(Statistics.wilsonLowerBound(successes: 3, trials: 3), 0.438494, accuracy: 1e-5)
        XCTAssertEqual(Statistics.wilsonLowerBound(successes: 19, trials: 20), 0.763864, accuracy: 1e-5)
        XCTAssertEqual(Statistics.wilsonLowerBound(successes: 20, trials: 20), 0.838870, accuracy: 1e-5)
        XCTAssertEqual(Statistics.wilsonLowerBound(successes: 35, trials: 35), 0.901096, accuracy: 1e-5)
        XCTAssertEqual(Statistics.wilsonLowerBound(successes: 73, trials: 73), 0.950006, accuracy: 1e-5)
        XCTAssertEqual(Statistics.wilsonLowerBound(successes: 40, trials: 60), 0.540566, accuracy: 1e-5)
    }

    func testThreeForThreeIsNotEvidenceOfANinetyPercentPassRate() {
        // The headline claim of this package, as an assertion. A gate that
        // compared the *observed* rate would see 1.0 here and go green.
        let observed = Saturating.rate(3, of: 3)
        XCTAssertEqual(observed, 1.0)
        XCTAssertLessThan(Statistics.wilsonLowerBound(successes: 3, trials: 3), 0.5)
    }

    /// The textbook alternative this package deliberately does not use:
    /// `p ± z·sqrt(p(1-p)/n)`. Implemented here, in the test target, purely so
    /// the comparison below is a real side-by-side rather than a claim in a
    /// comment.
    private func waldLowerBound(successes: Int, trials: Int, z: Double = Statistics.Z.ninetyFive) -> Double {
        guard trials > 0 else { return 0 }
        let p = Double(successes) / Double(trials)
        return p - z * (p * (1 - p) / Double(trials)).squareRoot()
    }

    func testWilsonDoesNotCollapseWhereWaldWould() {
        // The negative control for the package's central claim, run against an
        // actual competing implementation rather than against prose.
        //
        // At `p == 1` the Wald radical is zero for every `n`, so Wald certifies
        // a perfect pass rate from five samples. Wilson does not, and that gap
        // is the entire reason for the extra algebra.
        for n in [3, 5, 20, 10_000] {
            XCTAssertEqual(waldLowerBound(successes: n, trials: n), 1.0, accuracy: 1e-12,
                           "Wald must collapse to a point at p == 1 for n = \(n)")
            XCTAssertLessThan(Statistics.wilsonLowerBound(successes: n, trials: n), 1.0,
                              "Wilson must stay strictly below 1.0 for n = \(n)")
        }
        // And the gap at small n is enormous, not a rounding difference: Wald
        // says 1.0, Wilson says 0.5655.
        XCTAssertEqual(Statistics.wilsonLowerBound(successes: 5, trials: 5), 0.565509, accuracy: 1e-5)
        XCTAssertGreaterThan(waldLowerBound(successes: 5, trials: 5) - Statistics.wilsonLowerBound(successes: 5, trials: 5), 0.43)
        // Away from the boundary the two agree to within a few points, which is
        // why the boundary case is the one that matters.
        XCTAssertEqual(waldLowerBound(successes: 15, trials: 20), Statistics.wilsonLowerBound(successes: 15, trials: 20), accuracy: 0.05)
    }

    func testWilsonBoundIsMonotonicInSampleSizeForPerfectRuns() {
        var previous = 0.0
        for n in 1...200 {
            let bound = Statistics.wilsonLowerBound(successes: n, trials: n)
            XCTAssertGreaterThan(bound, previous)
            XCTAssertLessThan(bound, 1.0)
            previous = bound
        }
    }

    func testWilsonHandlesDegenerateInputsWithoutTrapping() {
        XCTAssertEqual(Statistics.wilsonInterval(successes: 0, trials: 0), 0...1)
        XCTAssertEqual(Statistics.wilsonInterval(successes: 5, trials: -3), 0...1)
        // Successes above trials is a caller bug; clamping yields the
        // conservative all-pass answer rather than an interval outside 0...1.
        // Asserted against the precomputed 10/10 value rather than against
        // another call to the function under test.
        XCTAssertEqual(Statistics.wilsonLowerBound(successes: 99, trials: 10), 0.722460, accuracy: 1e-5)
        // Negative successes clamp to zero. The lower bound alone would be 0
        // either way (the final `0...1` clamp would catch it), so the *upper*
        // bound is what distinguishes clamping from not clamping: unclamped,
        // `p̂ = -0.5` produces a negative centre and an upper bound of 0.
        let negative = Statistics.wilsonInterval(successes: -5, trials: 10)
        let zero = Statistics.wilsonInterval(successes: 0, trials: 10)
        XCTAssertEqual(negative.lowerBound, zero.lowerBound, accuracy: 1e-12)
        XCTAssertEqual(negative.upperBound, zero.upperBound, accuracy: 1e-12)
        XCTAssertGreaterThan(negative.upperBound, 0.2)
        // A non-finite or negative z falls back to 95% rather than producing
        // NaN bounds: 9/10 at z = 1.96 is 0.595844.
        XCTAssertEqual(Statistics.wilsonLowerBound(successes: 9, trials: 10, z: .nan), 0.595844, accuracy: 1e-5)
        XCTAssertEqual(Statistics.wilsonLowerBound(successes: 9, trials: 10, z: -1), 0.595844, accuracy: 1e-5)
        // 0 of 20, precomputed. Asserting only "inside 0...1" would be
        // vacuously true — `wilsonInterval` clamps both ends by construction.
        let bounds = Statistics.wilsonInterval(successes: 0, trials: 20)
        XCTAssertEqual(bounds.lowerBound, 0, accuracy: 1e-12)
        XCTAssertEqual(bounds.upperBound, 0.161130, accuracy: 1e-5)
    }

    // MARK: - Policy feasibility

    func testMinimumPerfectRunsMatchesHandComputedThresholds() {
        // For a perfect run the Wilson lower bound simplifies to n / (n + z²),
        // so these are checkable by hand: with z² = 3.8416, 0.90 needs n ≥ 34.6
        // and 0.95 needs n ≥ 73.0.
        XCTAssertEqual(GatePolicy.minimumPerfectRuns(toReach: 0.90), 35)
        XCTAssertEqual(GatePolicy.minimumPerfectRuns(toReach: 0.95), 73)
        XCTAssertEqual(GatePolicy.minimumPerfectRuns(toReach: 0.50), 4)
        XCTAssertEqual(GatePolicy.minimumPerfectRuns(toReach: 0), 1)
        // No finite sample reaches 1.0, because the bound is strictly below 1.
        XCTAssertNil(GatePolicy.minimumPerfectRuns(toReach: 1.0))
        XCTAssertNil(GatePolicy.minimumPerfectRuns(toReach: .nan))
    }

    func testTheBoundaryRunCountIsActuallyTheBoundary() {
        // 35 clears 0.90; 34 does not. If the binary search were off by one,
        // one of these fails.
        XCTAssertGreaterThanOrEqual(Statistics.wilsonLowerBound(successes: 35, trials: 35), 0.90)
        XCTAssertLessThan(Statistics.wilsonLowerBound(successes: 34, trials: 34), 0.90)
    }

    func testShippedPresetsAreAchievable() {
        for policy in [GatePolicy.standard, .strict, .exploratory] {
            XCTAssertTrue(policy.feasibility.isAchievable, "preset with threshold \(policy.requiredPassRateLowerBound) cannot pass")
        }
        XCTAssertEqual(GatePolicy.standard.feasibility, .achievable(minimumRunsNeeded: 35))
        XCTAssertEqual(GatePolicy.strict.feasibility, .achievable(minimumRunsNeeded: 73))
        // The exploratory preset needs only 4 perfect runs, but its own minimum
        // is 5, so the reported figure is the larger of the two.
        XCTAssertEqual(GatePolicy.exploratory.feasibility, .achievable(minimumRunsNeeded: 5))
    }

    func testAPolicyThatCanNeverPassIsReportedAsSuch() {
        // The misconfiguration this package exists to catch: a 95% bar with a
        // 10-run ceiling. A perfect sweep reaches only ~0.72.
        let impossible = GatePolicy(minimumRuns: 5, maximumRuns: 10, requiredPassRateLowerBound: 0.95)
        guard case .unachievable(let best, let runsNeeded) = impossible.feasibility else {
            return XCTFail("a 0.95 bar with a 10-run ceiling must be reported as unachievable")
        }
        XCTAssertEqual(best, 0.722460, accuracy: 1e-5)
        XCTAssertEqual(runsNeeded, 73)

        // And a threshold of exactly 1.0 is unachievable with no finite answer.
        let perfectionist = GatePolicy(minimumRuns: 1, maximumRuns: 1_000, requiredPassRateLowerBound: 1.0)
        guard case .unachievable(_, let none) = perfectionist.feasibility else {
            return XCTFail("a 1.0 threshold must be reported as unachievable")
        }
        XCTAssertNil(none)
    }

    func testPolicyNormalisesNonsenseConfiguration() {
        let policy = GatePolicy(minimumRuns: -4, maximumRuns: -9, requiredPassRateLowerBound: .nan, confidenceZ: -1)
        XCTAssertEqual(policy.minimumRuns, 1)
        XCTAssertEqual(policy.maximumRuns, 1)
        XCTAssertEqual(policy.confidenceZ, Statistics.Z.ninetyFive)
        // NaN falls back to a strict default rather than clamping to 0, which
        // would silently produce a gate that passes everything.
        XCTAssertEqual(policy.requiredPassRateLowerBound, 0.9)
    }

    // MARK: - Early stopping

    func testEarlyStopTriggersOnlyWhenTheVerdictCannotChange() {
        let policy = GatePolicy.standard  // 20...60 runs, bound ≥ 0.90

        // Nothing decided yet: below the minimum run count.
        XCTAssertFalse(policy.shouldStopEarly(successes: 10, trials: 10))
        // 20 failures: even 40 more perfect runs reach only ~0.54.
        XCTAssertTrue(policy.shouldStopEarly(successes: 0, trials: 20))
        XCTAssertEqual(
            Statistics.bestReachableLowerBound(successes: 0, trialsSoFar: 20, maximumTrials: 60),
            0.540566,
            accuracy: 1e-5
        )
        // Mid-sweep with the outcome genuinely open: 25 perfect runs have not
        // yet reached 0.90 (the bound is 0.867), but a perfect finish at 60
        // would reach 0.940 — so keep sampling.
        XCTAssertEqual(Statistics.wilsonLowerBound(successes: 25, trials: 25), 0.866804, accuracy: 1e-5)
        XCTAssertEqual(Statistics.wilsonLowerBound(successes: 60, trials: 60), 0.939826, accuracy: 1e-5)
        XCTAssertFalse(policy.shouldStopEarly(successes: 25, trials: 25))
        // Two failures at 40 runs already doom the sweep: even 20 perfect runs
        // to finish reach only 0.886, under the 0.90 bar. Stopping here is the
        // point of sequential testing — those 20 runs would have cost money and
        // changed nothing.
        XCTAssertEqual(Statistics.wilsonLowerBound(successes: 58, trials: 60), 0.886360, accuracy: 1e-5)
        XCTAssertTrue(policy.shouldStopEarly(successes: 38, trials: 40))
        // At the ceiling there is nothing to stop early from.
        XCTAssertFalse(policy.shouldStopEarly(successes: 60, trials: 60))
        // A policy with early stopping disabled never stops.
        let patient = GatePolicy(minimumRuns: 20, maximumRuns: 60, requiredPassRateLowerBound: 0.90, allowsEarlyStop: false)
        XCTAssertFalse(patient.shouldStopEarly(successes: 0, trials: 20))
    }

    // MARK: - Drift

    func testDriftSeparatesARealDropFromSamplingNoise() throws {
        let real = try XCTUnwrap(FlakeClassifier.drift(current: (43, 60), baseline: (57, 60)))
        XCTAssertEqual(real.z, -3.429286, accuracy: 1e-5)
        XCTAssertTrue(real.isSignificant)

        let noise = try XCTUnwrap(FlakeClassifier.drift(current: (58, 60), baseline: (57, 60)))
        XCTAssertEqual(noise.z, 0.456832, accuracy: 1e-5)
        XCTAssertFalse(noise.isSignificant)
    }

    func testDriftIsUndefinedRatherThanZeroWhenItCannotBeComputed() {
        XCTAssertNil(FlakeClassifier.drift(current: (0, 0), baseline: (57, 60)))
        // Both samples pinned at the same boundary: the pooled standard error
        // is zero, so the statistic is undefined rather than "no change".
        XCTAssertNil(FlakeClassifier.drift(current: (10, 10), baseline: (20, 20)))
        XCTAssertNil(FlakeClassifier.drift(current: (0, 10), baseline: (0, 20)))
    }

    // MARK: - Flake classification

    func testStabilityLabelsRequireEnoughRuns() {
        // One passing run is not "stable". Calling it that is how a one-sample
        // gate launders itself into a green check.
        XCTAssertEqual(FlakeClassifier.classify(outcomes: [true], minimumRuns: 20), .insufficientData(runs: 1, required: 20))
        XCTAssertEqual(FlakeClassifier.classify(outcomes: [], minimumRuns: 1), .insufficientData(runs: 0, required: 1))
        XCTAssertEqual(FlakeClassifier.classify(outcomes: [true, true, true], minimumRuns: 3), .stablePassing(runs: 3))
        XCTAssertEqual(FlakeClassifier.classify(outcomes: [false, false, false], minimumRuns: 3), .stableFailing(runs: 3))
    }

    func testFlakyVerdictCarriesANumber() throws {
        let verdict = FlakeClassifier.classify(outcomes: [true, false, true, true], minimumRuns: 4)
        guard case .flaky(let passes, let runs, let lowerBound) = verdict else {
            return XCTFail("mixed outcomes must classify as flaky")
        }
        XCTAssertEqual(passes, 3)
        XCTAssertEqual(runs, 4)
        // Precomputed, not fetched from the function that produced it.
        XCTAssertEqual(lowerBound, 0.300636, accuracy: 1e-5)
        XCTAssertTrue(verdict.describesInstability)
    }

    func testAlternationRateDistinguishesARegimeChangeFromNoise() {
        let regimeChange = [true, true, true, true, true, false, false, false, false, false]
        let noisy = [true, false, true, false, true, false, true, false, true, false]
        // Both classify identically — 5 of 10, bound 0.236590 — which is the
        // setup, not the assertion: a `classify` that returned a constant would
        // also satisfy an equality check between the two, so both verdicts are
        // pinned to precomputed values instead.
        for outcomes in [regimeChange, noisy] {
            guard case .flaky(let passes, let runs, let bound) = FlakeClassifier.classify(outcomes: outcomes, minimumRuns: 10) else {
                return XCTFail("5 of 10 must classify as flaky")
            }
            XCTAssertEqual(passes, 5)
            XCTAssertEqual(runs, 10)
            XCTAssertEqual(bound, 0.236590, accuracy: 1e-5)
        }
        // Identical pass rates, very different stories — and the alternation
        // rate is where the difference shows up.
        XCTAssertEqual(FlakeClassifier.alternationRate(outcomes: regimeChange), 1.0 / 9.0, accuracy: 1e-12)
        XCTAssertEqual(FlakeClassifier.alternationRate(outcomes: noisy), 1.0, accuracy: 1e-12)
        XCTAssertEqual(FlakeClassifier.alternationRate(outcomes: [true]), 0)
    }

    // MARK: - Judge calibration

    func testRubberStampJudgeIsRejectedDespiteHighRawAgreement() {
        // A judge that answers "pass" to everything, against a dataset that is
        // 90% passing. Raw agreement is 0.90 — which is why raw agreement is
        // not the test. Kappa is 0: the judge adds no information at all.
        let samples = (0..<50).map { index in
            CalibrationSample(judgeSaysPass: true, humanSaysPass: index % 10 != 0)
        }
        let report = JudgeCalibration.report(for: samples)
        XCTAssertEqual(report.rawAgreement, 0.90, accuracy: 1e-12)
        XCTAssertEqual(report.cohensKappa ?? .nan, 0, accuracy: 1e-12)
        // Every failure the human found was waved through.
        XCTAssertEqual(report.missedFailureRate, 1.0, accuracy: 1e-12)
        XCTAssertFalse(JudgeCalibration.verdict(for: samples).isTrusted)
    }

    func testAJudgeThatDisagreesWithNobodyIsUndefinedNotPerfect() {
        // Judge and human both say "pass" every time. Chance agreement is 1, so
        // kappa is undefined — reported as untrusted rather than as a NaN that
        // quietly compares false against the threshold.
        let samples = (0..<40).map { _ in CalibrationSample(judgeSaysPass: true, humanSaysPass: true) }
        XCTAssertNil(JudgeCalibration.report(for: samples).cohensKappa)
        guard case .untrusted(let reason) = JudgeCalibration.verdict(for: samples) else {
            return XCTFail("a constant rater must not be trusted")
        }
        XCTAssertTrue(reason.contains("chance"))
    }

    func testAWellCalibratedJudgeIsTrusted() {
        // 40 samples, balanced, with two disagreements in each direction.
        var samples: [CalibrationSample] = []
        for index in 0..<40 {
            let human = index % 2 == 0
            let judge = (index == 3 || index == 6) ? !human : human
            samples.append(CalibrationSample(judgeSaysPass: judge, humanSaysPass: human))
        }
        guard case .trusted(let kappa) = JudgeCalibration.verdict(for: samples) else {
            return XCTFail("a judge agreeing on 38 of 40 balanced samples must be trusted")
        }
        XCTAssertGreaterThan(kappa, 0.85)
        XCTAssertLessThanOrEqual(kappa, 1.0)
    }

    func testTooFewLabelledSamplesIsRejectedOnSampleSizeAlone() {
        let perfect = (0..<8).map { index in
            CalibrationSample(judgeSaysPass: index % 2 == 0, humanSaysPass: index % 2 == 0)
        }
        guard case .untrusted(let reason) = JudgeCalibration.verdict(for: perfect) else {
            return XCTFail("8 samples is not enough to trust a judge, however perfect")
        }
        XCTAssertTrue(reason.contains("labelled samples"))
        // With the sample-size bar lowered, the same data is trusted — proving
        // the rejection above was about sample size and nothing else.
        XCTAssertTrue(JudgeCalibration.verdict(for: perfect, minimumSampleCount: 8).isTrusted)
    }

    func testCalibrationCountsAreClampedRatherThanTrusted() {
        let report = CalibrationReport(truePositives: -5, falsePositives: 0, falseNegatives: 0, trueNegatives: 10)
        XCTAssertEqual(report.truePositives, 0)
        XCTAssertEqual(report.sampleCount, 10)
    }
}
