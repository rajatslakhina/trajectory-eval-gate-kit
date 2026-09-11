import XCTest
@testable import TrajectoryEvalGate

/// Arithmetic, hashing, and argument-matcher behaviour — the layer where a bug
/// is a crash rather than a wrong verdict.
final class PrimitiveTests: XCTestCase {

    // MARK: - Trap-free arithmetic

    func testClampedToIntHandlesEveryTrappingInput() {
        // `Int(Double.nan)` traps. All three of these are reachable from a
        // judge score or a cost model.
        XCTAssertEqual(Saturating.clampedToInt(.nan, fallback: -7), -7)
        XCTAssertEqual(Saturating.clampedToInt(.infinity), Int.max)
        XCTAssertEqual(Saturating.clampedToInt(-.infinity), Int.min)
        XCTAssertEqual(Saturating.clampedToInt(1e300), Int.max)
        XCTAssertEqual(Saturating.clampedToInt(-1e300), Int.min)
        XCTAssertEqual(Saturating.clampedToInt(42.9), 42)
        XCTAssertEqual(Saturating.clampedToInt(-42.9), -42)
    }

    func testIntConversionBoundsAreSafeOnThisPlatformsIntWidth() {
        // The watchOS case, where `Int` is 32-bit and a hardcoded 64-bit
        // literal ceiling would be a silent trap. Asserting the constant equals
        // `Double(Int.max)` would only restate its definition, so these assert
        // the behaviour instead: the exact platform boundaries convert without
        // trapping, and one ulp beyond them saturates.
        //
        // `Double(Int.max)` rounds *up* past `Int.max` on 64-bit (2^63 is not
        // an `Int` but is an exact `Double`), so this call is the one that
        // would trap without the strict `<`.
        XCTAssertEqual(Saturating.clampedToInt(Double(Int.max)), Int.max)
        XCTAssertEqual(Saturating.clampedToInt(Double(Int.min)), Int.min)
        XCTAssertEqual(Saturating.clampedToInt(Double(Int.max).nextUp), Int.max)
        XCTAssertEqual(Saturating.clampedToInt(Double(Int.min).nextDown), Int.min)
        // And a value comfortably inside the range still round-trips. Chosen to
        // be exactly representable as a `Double` on both 32- and 64-bit `Int`:
        // `Double(Int.max / 4)` is not, and would fail by one.
        XCTAssertEqual(Saturating.clampedToInt(1_000_000), 1_000_000)
        XCTAssertEqual(Saturating.clampedToInt(-1_000_000), -1_000_000)
    }

    // MARK: - Untrusted nesting depth

    func testDeeplyNestedArgumentValueIsTruncatedRatherThanOverflowingTheStack() {
        // Tool arguments are JSON from a backend, so their *depth* is untrusted
        // input to three recursive walkers: `==`, `hash(into:)` and
        // `description`. Without the boundary normalisation in `ToolCall.init`
        // those walkers recurse once per level of whatever a backend sends;
        // 2,000 is chosen to be comfortably survivable so the *assertion* is
        // about truncation rather than about surviving, but the real hazard is
        // a 100k-deep payload, where the failure mode is a stack overflow — a
        // crash rather than a catchable error, taking the whole CI job down
        // instead of failing one case.
        var deep = ArgumentValue.int(1)
        for _ in 0..<2_000 {
            deep = .list([deep])
        }

        let call = ToolCall(name: "t", arguments: ["payload": deep])
        let stored = call.arguments["payload"]
        XCTAssertNotNil(stored)

        // Equality, hashing and description all complete instead of trapping.
        XCTAssertEqual(call, ToolCall(name: "t", arguments: ["payload": deep]))
        XCTAssertEqual(Set([call]).count, 1)
        XCTAssertTrue(stored?.description.contains(ArgumentValue.truncationMarker) ?? false)

        // And the stored value really is bounded: peeling `maximumDepth` layers
        // reaches the marker rather than more list.
        var cursor = stored
        var peeled = 0
        while case .list(let inner) = cursor, let first = inner.first {
            cursor = first
            peeled += 1
            if peeled > ArgumentValue.maximumDepth { break }
        }
        XCTAssertEqual(peeled, ArgumentValue.maximumDepth)
        XCTAssertEqual(cursor, .string(ArgumentValue.truncationMarker))
    }

    func testShallowValuesAreUntouchedByTheDepthLimit() {
        // The normalisation must not alter anything a real tool would send.
        let value = ArgumentValue.object([
            "sku": .string("THD-1"),
            "tags": .list([.string("a"), .int(2), .bool(true), .null])
        ])
        XCTAssertEqual(ToolCall(name: "t", arguments: ["v": value]).arguments["v"], value)
        XCTAssertEqual(value.depthLimited(), value)
    }

    func testDeeplyNestedMatcherLiteralIsNormalisedAtTheContractBoundary() {
        var deep = ArgumentValue.int(1)
        for _ in 0..<2_000 {
            deep = .list([deep])
        }
        // `ExpectedStep.init` normalises, so the matcher a step holds can never
        // recurse without a ceiling either.
        let step = ExpectedStep(toolName: "t", arguments: ["v": .equals(deep)])
        guard case .equals(let normalised)? = step.arguments["v"] else {
            return XCTFail("expected an `.equals` matcher")
        }
        XCTAssertNotEqual(normalised, deep)
        XCTAssertTrue(normalised.description.contains(ArgumentValue.truncationMarker))
        // It still evaluates, and still fails to match an ordinary value.
        XCTAssertNotNil(step.arguments["v"]?.evaluate(key: "v", value: .int(1)))
    }

    func testOverDeepCompositeMatcherNormalisesToOneThatNeverMatches() {
        let overDepth = ArgumentMatcher.maximumNestingDepth + 20
        var matcher = ArgumentMatcher.any
        for _ in 0..<overDepth {
            matcher = .allOf([matcher])
        }
        let normalised = matcher.normalized()

        // Asserting only that `evaluate` reports a mismatch would prove
        // nothing: the runtime depth guard already does that for the
        // *un-normalised* matcher, so a `normalized()` gutted to `return self`
        // would pass. The assertion is therefore structural — the tree really
        // was rewritten.
        XCTAssertNotEqual(normalised, matcher)

        // Peeling `maximumNestingDepth` layers reaches the substituted
        // `.anyOf([])` sentinel, not more `.allOf`.
        var cursor = normalised
        var peeled = 0
        while case .allOf(let inner) = cursor, let first = inner.first {
            cursor = first
            peeled += 1
            if peeled > ArgumentMatcher.maximumNestingDepth { break }
        }
        XCTAssertEqual(peeled, ArgumentMatcher.maximumNestingDepth)
        XCTAssertEqual(cursor, .anyOf([]))

        // `.anyOf([])` never matches and says why, rather than collapsing to a
        // silently-passing `.any`.
        XCTAssertNotNil(normalised.evaluate(key: "k", value: .int(1)))
        XCTAssertNotNil(ArgumentMatcher.anyOf([]).evaluate(key: "k", value: .int(1)))
    }

    func testIntegerOperationsSaturateInsteadOfTrapping() {
        XCTAssertEqual(Saturating.add(Int.max, 1), Int.max)
        XCTAssertEqual(Saturating.add(Int.min, -1), Int.min)
        XCTAssertEqual(Saturating.subtract(Int.min, 1), Int.min)
        XCTAssertEqual(Saturating.subtract(Int.max, -1), Int.max)
        XCTAssertEqual(Saturating.multiply(Int.max, 2), Int.max)
        XCTAssertEqual(Saturating.multiply(Int.max, -2), Int.min)
        XCTAssertEqual(Saturating.multiply(Int.min, -1), Int.max)
        // The one overflowing division in two's complement.
        XCTAssertEqual(Saturating.divide(Int.min, by: -1), Int.max)
        XCTAssertEqual(Saturating.divide(10, by: 0, fallback: 99), 99)
        XCTAssertEqual(Saturating.divide(10, by: 3), 3)
    }

    func testRatioRejectsNonFiniteInputs() {
        XCTAssertEqual(Saturating.ratio(1, 0), 0)
        XCTAssertEqual(Saturating.ratio(.nan, 1), 0)
        XCTAssertEqual(Saturating.ratio(1, .infinity), 0)
        XCTAssertEqual(Saturating.rate(3, of: 4), 0.75)
        XCTAssertEqual(Saturating.rate(3, of: 0), 0)
    }

    func testClampMapsNaNToTheConservativeBound() {
        // Deliberate: an unknown score must not read as a good one.
        XCTAssertEqual(Saturating.clamp(Double.nan, to: 0...1), 0)
        XCTAssertEqual(Saturating.clamp(2.0, to: 0...1), 1)
    }

    // MARK: - Deterministic hashing

    func testStableHashMatchesAPrecomputedConstant() {
        // Asserting `stableHash(x) == stableHash(x)` inside one process would
        // also hold for `Hasher`, which is exactly the bug this function
        // exists to avoid — `Hasher` is seeded per process, so a "deterministic"
        // backend built on it reseeds on every CI run.
        //
        // These constants were computed out-of-band (FNV-1a 64-bit over UTF-8)
        // and are therefore process-independent by construction.
        XCTAssertEqual(stableHash("case-1"), 6_401_066_748_248_642_431)
        XCTAssertEqual(stableHash("price-check-barcode"), 2_823_136_018_560_653_510)
        XCTAssertEqual(stableHash("add-to-cart"), 14_996_390_108_819_769_171)
        XCTAssertEqual(stableHash(""), 0xcbf2_9ce4_8422_2325)
    }

    func testSplitMix64ProducesUniformValuesInUnitInterval() {
        var rng = SplitMix64(seed: 1)
        var minimum = 1.0
        var maximum = 0.0
        var total = 0.0
        let samples = 20_000
        for _ in 0..<samples {
            let value = rng.unitInterval()
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThan(value, 1)
            minimum = min(minimum, value)
            maximum = max(maximum, value)
            total += value
        }
        // A generator stuck on a constant, or one whose shift is wrong and
        // clusters in half the range, fails these.
        XCTAssertLessThan(minimum, 0.01)
        XCTAssertGreaterThan(maximum, 0.99)
        XCTAssertEqual(total / Double(samples), 0.5, accuracy: 0.02)
    }

    // MARK: - ArgumentValue equality

    func testNaNArgumentsCompareEqualToThemselves() {
        let a = ArgumentValue.double(.nan)
        let b = ArgumentValue.double(.nan)
        // Synthesised `Equatable` would make this false, and a golden
        // trajectory containing a NaN would never match a replay of itself.
        XCTAssertEqual(a, b)
        XCTAssertEqual(Set([a, b]).count, 1)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    func testNumericKindsAreNotCoerced() {
        XCTAssertNotEqual(ArgumentValue.int(1), ArgumentValue.double(1.0))
        XCTAssertNotEqual(ArgumentValue.int(1), ArgumentValue.string("1"))
    }

    func testNestedContainersCompareStructurally() {
        let left = ArgumentValue.object(["a": .list([.int(1), .double(.nan)])])
        let right = ArgumentValue.object(["a": .list([.int(1), .double(.nan)])])
        XCTAssertEqual(left, right)
        XCTAssertEqual(left.hashValue, right.hashValue)
    }

    // MARK: - Argument matchers

    func testMatchersEvaluateLeafCases() {
        XCTAssertNil(ArgumentMatcher.any.evaluate(key: "k", value: .int(3)))
        XCTAssertNotNil(ArgumentMatcher.any.evaluate(key: "k", value: nil))
        XCTAssertNil(ArgumentMatcher.absent.evaluate(key: "k", value: nil))
        XCTAssertNotNil(ArgumentMatcher.absent.evaluate(key: "k", value: .null))
        XCTAssertNil(ArgumentMatcher.present.evaluate(key: "k", value: .null))
        XCTAssertNil(ArgumentMatcher.intBetween(1, 10).evaluate(key: "q", value: .int(10)))
        XCTAssertNotNil(ArgumentMatcher.intBetween(1, 10).evaluate(key: "q", value: .int(11)))
        XCTAssertNotNil(ArgumentMatcher.intBetween(1, 10).evaluate(key: "q", value: .double(5)))
        XCTAssertNil(ArgumentMatcher.stringHasPrefix("THD-").evaluate(key: "sku", value: .string("THD-1")))
        XCTAssertNotNil(ArgumentMatcher.stringHasPrefix("THD-").evaluate(key: "sku", value: .string("SKU-1")))
    }

    func testMatchersRejectAssertionsThatWouldAssertNothing() {
        // An empty needle is contained in every string. Accepting it would turn
        // a typo into silent, permanent coverage.
        XCTAssertNotNil(ArgumentMatcher.stringContains("").evaluate(key: "q", value: .string("anything")))
        XCTAssertNotNil(ArgumentMatcher.stringHasPrefix("").evaluate(key: "q", value: .string("anything")))
        XCTAssertNotNil(ArgumentMatcher.oneOf([]).evaluate(key: "q", value: .int(1)))
        XCTAssertNotNil(ArgumentMatcher.anyOf([]).evaluate(key: "q", value: .int(1)))
    }

    func testDoubleBetweenRejectsNonFiniteValuesAndBounds() {
        XCTAssertNotNil(ArgumentMatcher.doubleBetween(0, 1).evaluate(key: "s", value: .double(.nan)))
        XCTAssertNotNil(ArgumentMatcher.doubleBetween(0, 1).evaluate(key: "s", value: .double(.infinity)))
        XCTAssertNotNil(ArgumentMatcher.doubleBetween(.nan, 1).evaluate(key: "s", value: .double(0.5)))
        XCTAssertNotNil(ArgumentMatcher.doubleBetween(1, 0).evaluate(key: "s", value: .double(0.5)))
        XCTAssertNil(ArgumentMatcher.doubleBetween(0, 1).evaluate(key: "s", value: .double(0.5)))
    }

    func testCaseInsensitiveContainsIsHonoured() {
        XCTAssertNil(ArgumentMatcher.stringContains("DRILL", caseSensitive: false)
            .evaluate(key: "q", value: .string("cordless drill")))
        XCTAssertNotNil(ArgumentMatcher.stringContains("DRILL", caseSensitive: true)
            .evaluate(key: "q", value: .string("cordless drill")))
    }

    func testDeeplyNestedMatcherIsRejectedRatherThanOverflowingTheStack() {
        // Matchers can be decoded from a dataset file, so their depth is
        // untrusted input to a recursive evaluator. Without the ceiling this
        // is a stack overflow, which is a crash rather than a catchable error.
        var matcher = ArgumentMatcher.any
        for _ in 0..<(ArgumentMatcher.maximumNestingDepth + 20) {
            matcher = .allOf([matcher])
        }
        let mismatch = matcher.evaluate(key: "k", value: .int(1))
        XCTAssertNotNil(mismatch)
        XCTAssertTrue(mismatch?.reason.contains("nesting") ?? false)
    }

    func testNestingJustUnderTheCeilingStillEvaluates() {
        var matcher = ArgumentMatcher.any
        for _ in 0..<(ArgumentMatcher.maximumNestingDepth - 1) {
            matcher = .allOf([matcher])
        }
        XCTAssertNil(matcher.evaluate(key: "k", value: .int(1)))
    }

    func testNotInvertsAndComposes() {
        XCTAssertNil(ArgumentMatcher.not(.equals(.int(1))).evaluate(key: "k", value: .int(2)))
        XCTAssertNotNil(ArgumentMatcher.not(.equals(.int(1))).evaluate(key: "k", value: .int(1)))
        let composite = ArgumentMatcher.allOf([.present, .not(.equals(.string("")))])
        XCTAssertNil(composite.evaluate(key: "k", value: .string("x")))
        XCTAssertNotNil(composite.evaluate(key: "k", value: .string("")))
    }

    func testStepReportsEveryFailingArgumentNotJustTheFirst() {
        let step = ExpectedStep(
            toolName: "addToCart",
            arguments: ["sku": .stringHasPrefix("THD-"), "quantity": .intBetween(1, 10)]
        )
        let call = ToolCall(name: "addToCart", arguments: ["sku": .string("X-1"), "quantity": .int(99)])
        XCTAssertEqual(step.mismatches(against: call).count, 2)
        // Sorted, so a CI diff is comparable to the previous run's.
        XCTAssertEqual(step.mismatches(against: call).map(\.key), ["quantity", "sku"])
    }
}
