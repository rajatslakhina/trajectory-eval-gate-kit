import XCTest
@testable import TrajectoryEvalGate

/// End-to-end sweeps against the deterministic backend.
final class RunnerTests: XCTestCase {

    // MARK: - Helpers

    private func singleCase(id: String = "case-1") -> EvalCase {
        EvalCase(id: id, prompt: "price?", expectation: Fixtures.barcodePriceCheck)
    }

    private func backend(
        passProbability: Double,
        errorProbability: Double = 0,
        id: String = "case-1",
        seed: UInt64 = 7
    ) -> DeterministicBackend {
        DeterministicBackend(
            identifier: "fake",
            seed: seed,
            behaviours: [
                id: CaseBehaviour(
                    golden: Fixtures.barcodeGolden,
                    degraded: Fixtures.barcodeDegraded,
                    passProbability: passProbability,
                    errorProbability: errorProbability,
                    tokensPerRun: 100
                )
            ]
        )
    }

    // MARK: - The headline behaviour

    func testAPerfectCaseStopsExactlyAtTheRunCountTheMathPredicts() async {
        // The feasibility arithmetic says a 0.90 lower bound needs 35 perfect
        // runs. This asserts the runner actually stops there — tying the static
        // prediction to the dynamic behaviour, which is the only way to know
        // the two agree.
        let runner = EvalGateRunner(backend: backend(passProbability: 1.0), budget: EvalBudget(maximumRuns: 1_000))
        let report = await runner.evaluate(cases: [singleCase()], policy: .standard)

        XCTAssertTrue(report.isGreen)
        let result = report.results[0]
        XCTAssertEqual(result.evidence.runs, 35)
        XCTAssertEqual(result.evidence.passes, 35)
        XCTAssertTrue(result.evidence.stoppedEarly)
        XCTAssertEqual(result.outcome, .pass)
        XCTAssertEqual(result.stability, .stablePassing(runs: 35))
        XCTAssertEqual(report.runsSpent, 35)
        XCTAssertEqual(report.tokensSpent, 3_500)
    }

    func testAnObservedRateThatClearsTheBarStillFailsTheGate() async {
        // The negative control for the package's central claim. A case that
        // passes 95% of the time looks fine to any "observed rate ≥ threshold"
        // gate. Its 95% lower bound at these sample sizes is not 0.95, and the
        // gate says so.
        //
        // 19 of 20 observed is a rate of 0.95 and a lower bound of 0.764.
        let evidence = GateEvidence(runs: 20, passes: 19, threshold: 0.90, z: Statistics.Z.ninetyFive, stoppedEarly: false)
        XCTAssertEqual(evidence.observedPassRate, 0.95, accuracy: 1e-12)
        XCTAssertGreaterThan(evidence.observedPassRate, evidence.threshold)
        XCTAssertEqual(evidence.passRateLowerBound, 0.763864, accuracy: 1e-5)
        XCTAssertFalse(evidence.clearsThreshold)
    }

    func testADegradedCaseFailsAndSaysWhy() async {
        let runner = EvalGateRunner(backend: backend(passProbability: 0.55), budget: EvalBudget(maximumRuns: 1_000))
        let report = await runner.evaluate(cases: [singleCase()], policy: .standard)

        XCTAssertFalse(report.isGreen)
        XCTAssertEqual(report.failingCases.count, 1)
        let result = report.results[0]
        guard case .fail(let reason) = result.outcome else {
            return XCTFail("a 55%-passing case must fail a 0.90 gate")
        }
        XCTAssertTrue(reason.contains("lower bound"))
        XCTAssertTrue(result.stability.describesInstability)
        // The diff from the first failing run is kept, so the report can say
        // what went wrong without storing every trajectory.
        XCTAssertNotNil(result.representativeDiff)
        XCTAssertEqual(result.representativeDiff?.unsatisfiedSteps.first?.step.toolName, DemoTool.lookUpProduct)
    }

    func testADeterministicFailureIsLabelledARegressionNotAFlake() async {
        let runner = EvalGateRunner(backend: backend(passProbability: 0.0), budget: EvalBudget(maximumRuns: 1_000))
        let report = await runner.evaluate(cases: [singleCase()], policy: .standard)
        let result = report.results[0]
        XCTAssertEqual(result.stability, .stableFailing(runs: 20))
        XCTAssertFalse(result.stability.describesInstability)
        // Stopped at the minimum: 20 failures already make the target
        // unreachable within the 60-run ceiling.
        XCTAssertEqual(result.evidence.runs, 20)
        XCTAssertTrue(result.evidence.stoppedEarly)
    }

    // MARK: - Determinism

    func testTheSameSeedProducesTheSameReport() async {
        let policy = GatePolicy.standard
        let first = await EvalGateRunner(backend: backend(passProbability: 0.8, seed: 99), budget: EvalBudget(maximumRuns: 500))
            .evaluate(cases: [singleCase()], policy: policy)
        let second = await EvalGateRunner(backend: backend(passProbability: 0.8, seed: 99), budget: EvalBudget(maximumRuns: 500))
            .evaluate(cases: [singleCase()], policy: policy)
        XCTAssertEqual(first, second)
    }

    func testDifferentSeedsExploreDifferentOutcomeSequences() async {
        // Guards against a seed that is accepted and then ignored — which would
        // make every "deterministic" test above pass for the wrong reason.
        let policy = GatePolicy(minimumRuns: 40, maximumRuns: 40, requiredPassRateLowerBound: 0.5, allowsEarlyStop: false)
        let a = await EvalGateRunner(backend: backend(passProbability: 0.5, seed: 1), budget: EvalBudget(maximumRuns: 500))
            .evaluate(cases: [singleCase()], policy: policy)
        let b = await EvalGateRunner(backend: backend(passProbability: 0.5, seed: 2), budget: EvalBudget(maximumRuns: 500))
            .evaluate(cases: [singleCase()], policy: policy)
        XCTAssertEqual(a.results[0].evidence.runs, 40)
        XCTAssertEqual(b.results[0].evidence.runs, 40)
        XCTAssertNotEqual(a.results[0].evidence.passes, b.results[0].evidence.passes)
    }

    // MARK: - Budget and errors

    func testAnUnderfundedSweepIsInconclusiveNotGreen() async {
        // The budget funds 5 runs; the policy needs 20 per case across 2 cases.
        // Nothing here is a statement about model quality, and the report must
        // not pretend otherwise.
        let cases = [singleCase(id: "case-1"), singleCase(id: "case-2")]
        let backend = DeterministicBackend(
            identifier: "fake",
            seed: 7,
            behaviours: [
                "case-1": CaseBehaviour(golden: Fixtures.barcodeGolden, degraded: Fixtures.barcodeDegraded, passProbability: 1.0),
                "case-2": CaseBehaviour(golden: Fixtures.barcodeGolden, degraded: Fixtures.barcodeDegraded, passProbability: 1.0)
            ]
        )
        let report = await EvalGateRunner(backend: backend, budget: EvalBudget(maximumRuns: 5))
            .evaluate(cases: cases, policy: .standard)

        XCTAssertFalse(report.isGreen)
        XCTAssertTrue(report.budgetExhausted)
        XCTAssertEqual(report.inconclusiveCases.count, 2)
        XCTAssertEqual(report.runsSpent, 5)
        // The second case never ran at all, and is reported as inconclusive
        // rather than omitted.
        XCTAssertEqual(report.results[1].evidence.runs, 0)
        XCTAssertEqual(report.results[1].stability, .insufficientData(runs: 0, required: 20))
    }

    func testBudgetSufficiencyIsComputableBeforeSpendingAnything() {
        let policy = GatePolicy.standard
        XCTAssertFalse(EvalBudget(maximumRuns: 5).isSufficient(for: policy, caseCount: 2))
        XCTAssertTrue(EvalBudget(maximumRuns: 40).isSufficient(for: policy, caseCount: 2))
        let derived = EvalBudget.sufficient(for: policy, caseCount: 3, tokensPerRun: 800)
        XCTAssertEqual(derived.maximumRuns, 180)
        XCTAssertEqual(derived.maximumTokens, 144_000)
        XCTAssertTrue(derived.isSufficient(for: policy, caseCount: 3))
    }

    func testTokenCeilingStopsTheSweep() async {
        // 100 tokens per run, 250-token ceiling: the sweep stops after the run
        // that crosses it. The documented overshoot is at most one run.
        let runner = EvalGateRunner(
            backend: backend(passProbability: 1.0),
            budget: EvalBudget(maximumRuns: 1_000, maximumTokens: 250)
        )
        let report = await runner.evaluate(cases: [singleCase()], policy: .standard)
        XCTAssertTrue(report.budgetExhausted)
        XCTAssertEqual(report.runsSpent, 3)
        XCTAssertEqual(report.tokensSpent, 300)
        XCTAssertEqual(report.inconclusiveCases.count, 1)
    }

    func testABackendThatAlwaysThrowsTerminatesAndIsInconclusive() async {
        // Errors count against the per-case attempt ceiling. Without that, this
        // loops forever: `outcomes.count` never grows.
        let alwaysErrors = backend(passProbability: 1.0, errorProbability: 1.0)
        let report = await EvalGateRunner(backend: alwaysErrors, budget: EvalBudget(maximumRuns: 1_000))
            .evaluate(cases: [singleCase()], policy: .standard)

        XCTAssertEqual(report.results[0].errorCount, GatePolicy.standard.maximumRuns)
        XCTAssertEqual(report.results[0].evidence.runs, 0)
        XCTAssertEqual(report.inconclusiveCases.count, 1)
        XCTAssertFalse(report.isGreen)
    }

    func testAnUnknownCaseIsInfrastructureNotAFailingModel() async {
        // The backend has no behaviour for this id, so every attempt throws.
        // Reporting it as `fail` would send someone to debug a prompt when the
        // real problem is a dataset/backend mismatch.
        let report = await EvalGateRunner(backend: backend(passProbability: 1.0, id: "other"), budget: EvalBudget(maximumRuns: 200))
            .evaluate(cases: [singleCase()], policy: .standard)
        XCTAssertEqual(report.inconclusiveCases.count, 1)
        XCTAssertEqual(report.failingCases.count, 0)
    }

    // MARK: - Report-level invariants

    func testAnEmptySweepIsNotGreen() async {
        let report = await EvalGateRunner(backend: backend(passProbability: 1.0), budget: EvalBudget(maximumRuns: 10))
            .evaluate(cases: [], policy: .standard)
        // The single most common way an eval gate becomes decorative: the
        // dataset fails to load, zero cases run, `allSatisfy` on an empty array
        // is `true`, and CI goes green.
        XCTAssertTrue(report.results.isEmpty)
        XCTAssertFalse(report.isGreen)
        XCTAssertTrue(report.headline.contains("not a pass"))
    }

    func testDriftAgainstABaselineIsSurfacedEvenWhenTheCaseStillPasses() async {
        // Baseline of 60/60; current behaviour is perfect too, so there is no
        // drift — and a case with a genuinely worse baseline shows the opposite.
        let steady = EvalCase(
            id: "case-1",
            prompt: "price?",
            expectation: Fixtures.barcodePriceCheck,
            baseline: BaselineRecord(passes: 34, runs: 35)
        )
        let report = await EvalGateRunner(backend: backend(passProbability: 1.0), budget: EvalBudget(maximumRuns: 200))
            .evaluate(cases: [steady], policy: .standard)
        XCTAssertTrue(report.isGreen)
        // 35/35 against a 34/35 baseline is within noise.
        XCTAssertEqual(report.results[0].driftIsSignificant, false)
        XCTAssertEqual(report.driftedCases.count, 0)
    }

    func testBaselineRecordClampsNonsense() {
        XCTAssertEqual(BaselineRecord(passes: 99, runs: 10).passes, 10)
        XCTAssertEqual(BaselineRecord(passes: -1, runs: -1).runs, 0)
        XCTAssertEqual(BaselineRecord(passes: -1, runs: -1).passes, 0)
    }

    func testHeadlineNamesTheThingsAReviewerNeeds() async {
        let runner = EvalGateRunner(backend: Fixtures.demoBackend(), budget: EvalBudget.sufficient(for: .standard, caseCount: 3))
        let report = await runner.evaluate(cases: Fixtures.demoCases, policy: .standard)
        XCTAssertTrue(report.headline.contains("EVAL GATE"))
        XCTAssertTrue(report.headline.contains("runs"))
        XCTAssertEqual(report.results.count, 3)
        // The shipped demo dataset is deliberately not all-green: the
        // shelf-label case sits at a pass rate that clears a naive majority
        // vote and fails a 0.90 confidence bound.
        XCTAssertFalse(report.isGreen)
        let shelf = report.results.first { $0.id == Fixtures.shelfLabelCaseID }
        XCTAssertNotNil(shelf)
        XCTAssertFalse(shelf?.outcome.isPass ?? true)
    }

    // MARK: - Concurrency

    func testConcurrentSweepsCannotOverspendTheBudget() async {
        // The reentrancy guard. Each sweep wants 20+ runs; the shared budget
        // allows 25 in total. If the reservation were a read-modify-write
        // spanning an `await`, both sweeps would read the same pre-increment
        // value and together spend more than 25.
        let runner = EvalGateRunner(backend: backend(passProbability: 1.0), budget: EvalBudget(maximumRuns: 25))
        let cases = [singleCase()]
        async let first = runner.evaluate(cases: cases, policy: .standard)
        async let second = runner.evaluate(cases: cases, policy: .standard)
        let reports = await [first, second]

        let spent = await runner.spentRuns
        XCTAssertEqual(spent, 25)
        XCTAssertLessThanOrEqual(reports.map(\.runsSpent).max() ?? 0, 25)
        // Neither sweep reached 35 runs, so neither can be green.
        XCTAssertTrue(reports.allSatisfy { !$0.isGreen })
    }
}
