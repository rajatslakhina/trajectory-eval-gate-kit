//
//  DeterministicBackend.swift
//  TrajectoryEvalGate
//
//  A backend that behaves like a stochastic model but is bit-for-bit
//  reproducible, so the gate's own behaviour can be tested.
//

/// SplitMix64 — small, fast, and with a documented period, which matters more
/// here than statistical excellence.
///
/// `SystemRandomNumberGenerator` is deliberately not used: a test that asserts
/// "this 12%-flaky case is classified as flaky" must produce the same 12% on
/// every machine and every run, or it becomes the flakiest test in the suite.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        // Any seed is valid, including zero: SplitMix64's increment is odd, so
        // the sequence has full period from any starting state.
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A `Double` in `[0, 1)`.
    mutating func unitInterval() -> Double {
        // 53 significant bits is exactly `Double`'s mantissa width, so every
        // value is representable and the distribution is uniform.
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }
}

/// FNV-1a over UTF-8 bytes.
///
/// Swift's `Hasher` is seeded per process, so `"case-1".hashValue` differs
/// between runs of the same binary. Seeding a "deterministic" backend from it
/// would produce a backend that is reproducible within a process and different
/// on every CI run — the exact failure this type exists to avoid, and one that
/// would not show up in a test that hashes the same string twice in one
/// process and asserts the results match.
func stableHash(_ string: String) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in string.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01B3
    }
    return hash
}

/// How one case should behave under sampling.
public struct CaseBehaviour: Sendable, Equatable {
    /// The trajectory emitted on a good run.
    public let golden: Trajectory
    /// The trajectory emitted on a bad run. Typically the golden one with a
    /// step dropped or an argument wrong.
    public let degraded: Trajectory
    /// Probability in `0...1` that a run emits `golden`.
    public let passProbability: Double
    /// Probability in `0...1` that a run throws instead of completing.
    /// Applied before the pass/fail draw.
    public let errorProbability: Double
    /// Tokens reported per run.
    public let tokensPerRun: Int

    public init(
        golden: Trajectory,
        degraded: Trajectory,
        passProbability: Double,
        errorProbability: Double = 0,
        tokensPerRun: Int = 500
    ) {
        self.golden = golden
        self.degraded = degraded
        self.passProbability = passProbability.isFinite ? Saturating.clamp(passProbability, to: 0...1) : 0
        self.errorProbability = errorProbability.isFinite ? Saturating.clamp(errorProbability, to: 0...1) : 0
        self.tokensPerRun = max(0, tokensPerRun)
    }
}

/// A reproducible stand-in for a real model.
///
/// Every run's outcome is a pure function of `(seed, case id, attempt)`, so the
/// same sweep produces the same report on every machine — which is what makes
/// it possible to write a test asserting that a 60%-passing case *fails* a
/// 90%-lower-bound gate.
public struct DeterministicBackend: EvaluationBackend {
    public let identifier: String
    private let seed: UInt64
    private let behaviours: [String: CaseBehaviour]

    public init(identifier: String = "deterministic-fake", seed: UInt64 = 0xD15E_A5E5, behaviours: [String: CaseBehaviour]) {
        self.identifier = identifier
        self.seed = seed
        self.behaviours = behaviours
    }

    public func run(_ evalCase: EvalCase, attempt: Int) async throws -> BackendRunResult {
        guard let behaviour = behaviours[evalCase.id] else {
            // An unknown case is an infrastructure error, not a failing run.
            // Reporting it as a failure would blame the model for a dataset
            // that does not line up with the backend's configuration.
            throw EvaluationBackendError.modelUnavailable("no behaviour configured for case `\(evalCase.id)`")
        }

        // `attempt` is folded in as an unsigned magnitude so that a negative
        // attempt index (a caller bug) cannot trap on conversion.
        let attemptComponent = UInt64(attempt.magnitude)
        var rng = SplitMix64(seed: (seed ^ stableHash(evalCase.id)) &+ (attemptComponent &* 0x9E37_79B9))

        let draw = rng.unitInterval()
        if draw < behaviour.errorProbability {
            throw EvaluationBackendError.transport("simulated transport failure on attempt \(attempt)")
        }

        // A second, independent draw: reusing `draw` would correlate the error
        // and quality outcomes, so a case with a 10% error rate would silently
        // lose its 10 worst-quality runs and look better than it is.
        let qualityDraw = rng.unitInterval()
        let passed = qualityDraw < behaviour.passProbability
        return BackendRunResult(
            trajectory: passed ? behaviour.golden : behaviour.degraded,
            tokensUsed: behaviour.tokensPerRun,
            judgeScore: passed ? 0.95 : 0.35
        )
    }
}
