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

    func testIntConversionCeilingIsDerivedNotHardcoded() {
        // Guards the watchOS case: a hardcoded 64-bit literal would be wrong on
        // a 32-bit `Int`, and this assertion is the only thing that would
        // notice.
        XCTAssertEqual(Saturating.intConversionCeiling, Double(Int.max))
        XCTAssertEqual(Saturating.intConversionFloor, Double(Int.min))
        // `Double(Int.max)` rounds up past `Int.max`, so converting it back
        // would trap. The strict `<` in `clampedToInt` is what stops that.
        XCTAssertEqual(Saturating.clampedToInt(Double(Int.max)), Int.max)
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
