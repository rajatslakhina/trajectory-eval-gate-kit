import XCTest
@testable import TrajectoryEvalGate

/// The matching engine. Several of these are negative controls: they construct
/// the case a simpler algorithm gets wrong and assert this one gets it right.
final class TrajectoryMatchingTests: XCTestCase {

    private func call(_ name: String, _ arguments: [String: ArgumentValue] = [:]) -> ToolCall {
        ToolCall(name: name, arguments: arguments)
    }

    // MARK: - Fixtures behave as documented

    func testGoldenTrajectoriesSatisfyTheirContracts() {
        XCTAssertTrue(TrajectoryMatcher.match(Fixtures.barcodeGolden, against: Fixtures.barcodePriceCheck).didMatch)
        XCTAssertTrue(TrajectoryMatcher.match(Fixtures.shelfLabelGolden, against: Fixtures.shelfLabelPriceCheck).didMatch)
        XCTAssertTrue(TrajectoryMatcher.match(Fixtures.addToCartGolden, against: Fixtures.addToCartFlow).didMatch)
    }

    func testDegradedTrajectoriesFailTheirContracts() {
        XCTAssertFalse(TrajectoryMatcher.match(Fixtures.barcodeDegraded, against: Fixtures.barcodePriceCheck).didMatch)
        XCTAssertFalse(TrajectoryMatcher.match(Fixtures.shelfLabelDegraded, against: Fixtures.shelfLabelPriceCheck).didMatch)
        XCTAssertFalse(TrajectoryMatcher.match(Fixtures.addToCartDegraded, against: Fixtures.addToCartFlow).didMatch)
    }

    func testSkippingAnOptionalStepStillMatches() {
        XCTAssertTrue(
            TrajectoryMatcher.match(Fixtures.shelfLabelGoldenWithoutOCR, against: Fixtures.shelfLabelPriceCheck).didMatch
        )
    }

    // MARK: - Negative control: greedy ordered matching

    func testOptionalStepDoesNotStealTheOnlyCallARequiredStepNeeds() {
        // Contract: an optional lookup, then a required lookup.
        // Observation: exactly one lookup.
        //
        // A greedy left-to-right walk spends the single call on the optional
        // step and then fails the required one. The DP skips the optional step
        // and matches. This trajectory is genuinely conformant, so a greedy
        // implementation would report a false failure here.
        let expectation = TrajectoryExpectation(
            steps: [
                ExpectedStep(toolName: "lookUp", isOptional: true),
                ExpectedStep(toolName: "lookUp")
            ],
            ordering: .subsequence
        )
        let trajectory = Trajectory(calls: [call("lookUp")])
        XCTAssertTrue(TrajectoryMatcher.match(trajectory, against: expectation).didMatch)

        // And the control in the other direction: with the optional step made
        // required, one call genuinely cannot satisfy two steps.
        let stricter = TrajectoryExpectation(
            steps: [ExpectedStep(toolName: "lookUp"), ExpectedStep(toolName: "lookUp")],
            ordering: .subsequence
        )
        XCTAssertFalse(TrajectoryMatcher.match(trajectory, against: stricter).didMatch)
    }

    // MARK: - Negative control: greedy unordered matching

    func testUnorderedMatchingReassignsAnAlreadyTakenCall() {
        // Steps: a permissive `search`, and a `search` that insists on page 1.
        // Calls: page 1, then page 2.
        //
        // Greedy assignment in step order gives the permissive step page 1,
        // leaving the picky step with only page 2, and reports a failure. The
        // augmenting-path search moves the permissive step to page 2 and
        // matches. The four assertions below pin the exact shape of that trap:
        // step 1 really cannot use call 1, so the only valid assignment is the
        // one greedy would never find.
        let permissive = ExpectedStep(toolName: "search")
        let picky = ExpectedStep(toolName: "search", arguments: ["page": .equals(.int(1))])
        let calls = [call("search", ["page": .int(1)]), call("search", ["page": .int(2)])]

        XCTAssertTrue(permissive.matches(calls[0]))
        XCTAssertTrue(permissive.matches(calls[1]))
        XCTAssertTrue(picky.matches(calls[0]))
        XCTAssertFalse(picky.matches(calls[1]))

        let expectation = TrajectoryExpectation(steps: [permissive, picky], ordering: .unordered)
        XCTAssertTrue(TrajectoryMatcher.match(Trajectory(calls: calls), against: expectation).didMatch)
    }

    func testUnorderedMatchingRequiresDistinctCallsPerStep() {
        // Two steps, one call that satisfies both. There is no valid
        // assignment: a single call cannot be spent twice.
        let step = ExpectedStep(toolName: "search")
        let expectation = TrajectoryExpectation(steps: [step, step], ordering: .unordered)
        XCTAssertFalse(TrajectoryMatcher.match(Trajectory(calls: [call("search")]), against: expectation).didMatch)
    }

    func testUnorderedIgnoresOrder() {
        let expectation = TrajectoryExpectation(
            steps: [ExpectedStep(toolName: "a"), ExpectedStep(toolName: "b")],
            ordering: .unordered
        )
        XCTAssertTrue(TrajectoryMatcher.match(Trajectory(calls: [call("b"), call("a")]), against: expectation).didMatch)

        let ordered = TrajectoryExpectation(
            steps: [ExpectedStep(toolName: "a"), ExpectedStep(toolName: "b")],
            ordering: .subsequence
        )
        XCTAssertFalse(TrajectoryMatcher.match(Trajectory(calls: [call("b"), call("a")]), against: ordered).didMatch)
    }

    // MARK: - Exact vs subsequence

    func testExactRejectsTheExtraCallSubsequenceTolerates() {
        let steps = [ExpectedStep(toolName: "lookUp"), ExpectedStep(toolName: "addToCart")]
        let trajectory = Trajectory(calls: [call("lookUp"), call("addToCart"), call("addToCart")])

        let exact = TrajectoryExpectation(steps: steps, ordering: .exact)
        let loose = TrajectoryExpectation(steps: steps, ordering: .subsequence)

        XCTAssertFalse(TrajectoryMatcher.match(trajectory, against: exact).didMatch)
        XCTAssertTrue(TrajectoryMatcher.match(trajectory, against: loose).didMatch)
    }

    func testSubsequenceToleratesInterleavedUnrelatedCalls() {
        let expectation = TrajectoryExpectation(
            steps: [ExpectedStep(toolName: "a"), ExpectedStep(toolName: "b")],
            ordering: .subsequence
        )
        let trajectory = Trajectory(calls: [call("noise"), call("a"), call("noise"), call("b"), call("noise")])
        XCTAssertTrue(TrajectoryMatcher.match(trajectory, against: expectation).didMatch)
    }

    // MARK: - Empty and boundary inputs

    func testEmptyInputsBehaveAsDocumented() {
        let empty = Trajectory(calls: [])
        let noSteps = TrajectoryExpectation(steps: [], ordering: .exact)
        XCTAssertTrue(TrajectoryMatcher.match(empty, against: noSteps).didMatch)

        // Under `.exact`, an empty contract tolerates no calls at all.
        XCTAssertFalse(TrajectoryMatcher.match(Trajectory(calls: [call("a")]), against: noSteps).didMatch)
        // Under `.subsequence`, it tolerates any.
        let looseNoSteps = TrajectoryExpectation(steps: [], ordering: .subsequence)
        XCTAssertTrue(TrajectoryMatcher.match(Trajectory(calls: [call("a")]), against: looseNoSteps).didMatch)
        // And `.unordered` with no required steps is vacuously satisfied.
        let unorderedNoSteps = TrajectoryExpectation(steps: [], ordering: .unordered)
        XCTAssertTrue(TrajectoryMatcher.match(empty, against: unorderedNoSteps).didMatch)

        // A required step against an empty trajectory fails, and says why.
        let oneStep = TrajectoryExpectation(steps: [ExpectedStep(toolName: "a")], ordering: .subsequence)
        let result = TrajectoryMatcher.match(empty, against: oneStep)
        XCTAssertFalse(result.didMatch)
        XCTAssertEqual(result.diff?.unsatisfiedSteps.first?.closestCallIndex, nil)
        XCTAssertTrue(result.diff?.summary.contains("never called") ?? false)

        // Only-optional steps against an empty trajectory match.
        let optionalOnly = TrajectoryExpectation(
            steps: [ExpectedStep(toolName: "a", isOptional: true)],
            ordering: .exact
        )
        XCTAssertTrue(TrajectoryMatcher.match(empty, against: optionalOnly).didMatch)
    }

    // MARK: - Ordering-independent rules

    func testForbiddenToolFailsEvenWhenEveryStepMatched() {
        let result = TrajectoryMatcher.match(Fixtures.forbiddenToolTrajectory, against: Fixtures.barcodePriceCheck)
        XCTAssertFalse(result.didMatch)
        XCTAssertEqual(result.diff?.forbiddenCallIndices, [2])
        // The steps themselves were satisfiable, so nothing is reported as
        // unsatisfied — the failure is the forbidden tool and only that.
        XCTAssertEqual(result.diff?.unsatisfiedSteps.count, 0)
    }

    func testCallCeilingIsEnforcedSeparatelyFromOrdering() {
        let expectation = TrajectoryExpectation(
            steps: [ExpectedStep(toolName: "a")],
            ordering: .subsequence,
            maximumCalls: 2
        )
        let trajectory = Trajectory(calls: [call("a"), call("a"), call("a")])
        let result = TrajectoryMatcher.match(trajectory, against: expectation)
        XCTAssertFalse(result.didMatch)
        XCTAssertEqual(result.diff?.callCeilingExceededAt, 3)
    }

    func testNonPositiveCallCeilingIsNormalisedAway() {
        // A dataset typo of `maximumCalls: 0` would otherwise produce a
        // contract that can never pass and that nobody would notice.
        XCTAssertNil(TrajectoryExpectation(steps: [], maximumCalls: 0).maximumCalls)
        XCTAssertNil(TrajectoryExpectation(steps: [], maximumCalls: -3).maximumCalls)
        XCTAssertEqual(TrajectoryExpectation(steps: [], maximumCalls: 4).maximumCalls, 4)
    }

    // MARK: - Search budget

    func testOversizedTrajectoryFailsLoudlyRatherThanHanging() {
        // A looping agent emitting a huge call list must not turn into an
        // unbounded DP allocation inside a CI job.
        let steps = (0..<40).map { _ in ExpectedStep(toolName: "a") }
        let calls = (0..<20_000).map { _ in self.call("a") }
        let expectation = TrajectoryExpectation(steps: steps, ordering: .subsequence)
        let result = TrajectoryMatcher.match(Trajectory(calls: calls), against: expectation)
        XCTAssertFalse(result.didMatch)
        XCTAssertEqual(result.diff?.analysisBudgetExceeded, true)
    }

    func testBudgetExceededIsNeverReportedAsAPass() {
        // Even a trajectory that would obviously have matched must not pass
        // when it could not actually be analysed.
        let steps = (0..<40).map { _ in ExpectedStep(toolName: "a", isOptional: true) }
        let calls = (0..<20_000).map { _ in self.call("a") }
        let expectation = TrajectoryExpectation(steps: steps, ordering: .subsequence)
        XCTAssertFalse(TrajectoryMatcher.match(Trajectory(calls: calls), against: expectation).didMatch)
    }

    func testTheSearchBudgetBoundaryIsExactlyWhereItClaimsToBe() {
        // The off-by-one on `cellCount > maximumSearchCells` is only verifiable
        // at the boundary itself. 249 steps x 999 calls is
        // (249 + 1) * (999 + 1) = 250,000 cells — exactly the ceiling — and
        // must be analysed. One more call is 250 * 1001 = 250,250 and must not.
        XCTAssertEqual(TrajectoryMatcher.maximumSearchCells, 250_000)

        // Steps are optional and name a tool no call uses, so the trajectory
        // genuinely matches by skipping everything — which makes "analysed"
        // and "not analysed" distinguishable by the verdict rather than only by
        // the diff flag.
        let steps = (0..<249).map { _ in ExpectedStep(toolName: "never-called", isOptional: true) }
        let atCeiling = (0..<999).map { _ in self.call("a") }
        let expectation = TrajectoryExpectation(steps: steps, ordering: .subsequence)

        let inside = TrajectoryMatcher.match(Trajectory(calls: atCeiling), against: expectation)
        XCTAssertTrue(inside.didMatch, "250,000 cells is exactly the ceiling and must be analysed")

        let overCeiling = atCeiling + [call("a")]
        let outside = TrajectoryMatcher.match(Trajectory(calls: overCeiling), against: expectation)
        XCTAssertFalse(outside.didMatch)
        XCTAssertEqual(outside.diff?.analysisBudgetExceeded, true)
    }

    func testUnorderedStepCeilingIsEnforced() {
        let steps = (0...TrajectoryMatcher.maximumUnorderedSteps).map { _ in ExpectedStep(toolName: "a") }
        let expectation = TrajectoryExpectation(steps: steps, ordering: .unordered)
        let result = TrajectoryMatcher.match(Trajectory(calls: [call("a")]), against: expectation)
        XCTAssertEqual(result.diff?.analysisBudgetExceeded, true)
    }

    // MARK: - Diagnostics

    func testDiagnosticsNameTheClosestCallAndTheFailingArgument() throws {
        let result = TrajectoryMatcher.match(Fixtures.shelfLabelDegraded, against: Fixtures.shelfLabelPriceCheck)
        let diff = try XCTUnwrap(result.diff)
        let unsatisfied = try XCTUnwrap(diff.unsatisfiedSteps.first)
        XCTAssertEqual(unsatisfied.step.toolName, DemoTool.lookUpProduct)
        XCTAssertEqual(unsatisfied.closestCallIndex, 1)
        XCTAssertEqual(unsatisfied.mismatches.first?.key, "sku")
        // The message names the expected prefix, so the failure is actionable
        // without re-running anything.
        XCTAssertTrue(diff.summary.contains("THD-"))
    }

    func testUnexpectedCallsAreReportedAsAHintNotAVerdict() {
        let expectation = TrajectoryExpectation(
            steps: [ExpectedStep(toolName: "a")],
            ordering: .exact
        )
        let result = TrajectoryMatcher.match(Trajectory(calls: [call("a"), call("surprise")]), against: expectation)
        XCTAssertFalse(result.didMatch)
        XCTAssertEqual(result.diff?.unexpectedCallIndices, [1])
        // Every step was individually satisfiable, so the diff blames ordering
        // rather than inventing a step-level cause.
        XCTAssertEqual(result.diff?.unsatisfiedSteps.count, 0)
    }

    func testCleanDiffIsReportedAsClean() {
        XCTAssertTrue(TrajectoryDiff().isClean)
        XCTAssertEqual(TrajectoryDiff().summary, "no differences")
        XCTAssertFalse(TrajectoryDiff(analysisBudgetExceeded: true).isClean)
    }
}
