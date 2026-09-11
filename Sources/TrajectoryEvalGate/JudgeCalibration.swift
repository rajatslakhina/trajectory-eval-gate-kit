//
//  JudgeCalibration.swift
//  TrajectoryEvalGate
//
//  Before a model-as-judge is allowed to fail a build, it has to prove it
//  agrees with a human on cases where the answer is already known.
//
//  Raw agreement is the trap. A judge that answers "pass" to everything scores
//  92% agreement against a dataset that is 92% passing, and contributes exactly
//  nothing — it would have produced the same verdicts with the model deleted.
//  Cohen's kappa removes the agreement expected by chance, and that rubber-stamp
//  judge scores approximately zero. There is a test for it: `testRubberStampJudge…`
//  feeds a deliberately broken judge that always says "pass" and asserts the
//  calibration check *rejects* it.
//

/// A single labelled example: what the judge said, and what a human said.
public struct CalibrationSample: Sendable, Equatable {
    public let judgeSaysPass: Bool
    public let humanSaysPass: Bool

    public init(judgeSaysPass: Bool, humanSaysPass: Bool) {
        self.judgeSaysPass = judgeSaysPass
        self.humanSaysPass = humanSaysPass
    }
}

/// The 2x2 confusion matrix plus the statistics derived from it.
public struct CalibrationReport: Sendable, Equatable {
    /// Judge pass, human pass.
    public let truePositives: Int
    /// Judge pass, human fail — the dangerous error: a regression waved through.
    public let falsePositives: Int
    /// Judge fail, human pass — the annoying error: a red build nobody trusts.
    public let falseNegatives: Int
    /// Judge fail, human fail.
    public let trueNegatives: Int

    public init(truePositives: Int, falsePositives: Int, falseNegatives: Int, trueNegatives: Int) {
        // Counts are clamped at zero: a negative count is a caller bug, and
        // letting it through would produce a kappa outside `-1...1` that reads
        // as a plausible number.
        self.truePositives = max(0, truePositives)
        self.falsePositives = max(0, falsePositives)
        self.falseNegatives = max(0, falseNegatives)
        self.trueNegatives = max(0, trueNegatives)
    }

    public var sampleCount: Int {
        Saturating.add(
            Saturating.add(truePositives, falsePositives),
            Saturating.add(falseNegatives, trueNegatives)
        )
    }

    /// Fraction of samples where judge and human agreed.
    public var rawAgreement: Double {
        Saturating.rate(Saturating.add(truePositives, trueNegatives), of: sampleCount)
    }

    /// Of the cases the human marked as failing, the fraction the judge waved
    /// through. This is the number to put in a slide.
    public var missedFailureRate: Double {
        Saturating.rate(falsePositives, of: Saturating.add(falsePositives, trueNegatives))
    }

    /// Cohen's kappa. `nil` when it is undefined — which happens whenever one
    /// rater is constant *and* the other's marginals make chance agreement
    /// exactly 1, i.e. both raters said the same single thing every time.
    public var cohensKappa: Double? {
        let n = sampleCount
        guard n > 0 else { return nil }
        let observedAgreement = rawAgreement

        let judgePassRate = Saturating.rate(Saturating.add(truePositives, falsePositives), of: n)
        let humanPassRate = Saturating.rate(Saturating.add(truePositives, falseNegatives), of: n)
        let expectedAgreement = judgePassRate * humanPassRate + (1 - judgePassRate) * (1 - humanPassRate)

        let denominator = 1 - expectedAgreement
        // Reachable whenever both raters are constant and identical, e.g. a
        // 10-sample set where judge and human both said "pass" every time.
        // Returning `nil` rather than dividing is the difference between an
        // honest "undefined" and a NaN that later compares false against every
        // threshold and reads as a quiet failure.
        guard denominator > 1e-12 else { return nil }
        return (observedAgreement - expectedAgreement) / denominator
    }
}

/// Whether a judge may be used as a gate.
public enum CalibrationVerdict: Sendable, Equatable {
    case trusted(kappa: Double)
    case untrusted(reason: String)

    public var isTrusted: Bool {
        if case .trusted = self { return true }
        return false
    }
}

public enum JudgeCalibration {

    /// Minimum labelled samples before a kappa means anything.
    ///
    /// Kappa on 8 samples has a confidence interval wide enough to cover both
    /// "excellent" and "worthless", so a small labelled set is rejected on
    /// sample size rather than passed on a lucky point estimate.
    public static let minimumSamples = 30

    /// Landis & Koch's "substantial agreement" boundary, used as the default
    /// bar. Chosen because it is the conventional threshold and because
    /// anything looser admits judges whose disagreement with a human is
    /// comparable to the regressions they are meant to catch.
    public static let defaultMinimumKappa = 0.60

    public static func report(for samples: [CalibrationSample]) -> CalibrationReport {
        var tp = 0, fp = 0, fn = 0, tn = 0
        for sample in samples {
            switch (sample.judgeSaysPass, sample.humanSaysPass) {
            case (true, true): tp += 1
            case (true, false): fp += 1
            case (false, true): fn += 1
            case (false, false): tn += 1
            }
        }
        return CalibrationReport(truePositives: tp, falsePositives: fp, falseNegatives: fn, trueNegatives: tn)
    }

    /// Decides whether a judge is calibrated well enough to gate a build.
    ///
    /// Three independent ways to be rejected, in order:
    ///   1. too few labelled samples,
    ///   2. kappa undefined — which happens only when *both* raters are
    ///      constant and identical, so chance agreement is exactly 1,
    ///   3. kappa below the bar.
    ///
    /// The rubber-stamp judge is caught by (3), not (2): against a 90%-passing
    /// set it has a perfectly well-defined kappa of exactly 0 (observed
    /// agreement 0.9, chance agreement 0.9, denominator 0.1). That is the point
    /// — a defined-but-zero kappa is what "this judge adds no information"
    /// looks like numerically.
    public static func verdict(
        for samples: [CalibrationSample],
        minimumKappa: Double = defaultMinimumKappa,
        minimumSampleCount: Int = minimumSamples
    ) -> CalibrationVerdict {
        let required = max(1, minimumSampleCount)
        guard samples.count >= required else {
            return .untrusted(reason: "only \(samples.count) labelled samples; \(required) required")
        }
        let report = report(for: samples)
        guard let kappa = report.cohensKappa else {
            return .untrusted(reason: "agreement is entirely explained by chance (one rater is constant); the judge adds no information")
        }
        let bar = minimumKappa.isFinite ? Saturating.clamp(minimumKappa, to: -1...1) : defaultMinimumKappa
        guard kappa >= bar else {
            let rounded = (kappa * 1000).rounded() / 1000
            return .untrusted(reason: "Cohen's kappa \(rounded) is below the required \(bar)")
        }
        return .trusted(kappa: kappa)
    }
}
