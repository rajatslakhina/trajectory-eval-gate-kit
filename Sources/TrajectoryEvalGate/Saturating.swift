//
//  Saturating.swift
//  TrajectoryEvalGate
//
//  Trap-free arithmetic helpers.
//
//  Rationale: an eval gate reads numbers it did not produce — run counts from a
//  CI matrix, token costs from a vendor response, scores from a model-as-judge.
//  Any of those can arrive as NaN, infinity, a negative count, or a value that
//  overflows on multiply. Swift traps on all of them, and a trap inside a CI
//  gate is indistinguishable from an infrastructure outage, so the gate stops
//  being trustworthy exactly when it matters.
//
//  Every arithmetic operation in this package that could trap routes through
//  one of these functions rather than scattering `guard` statements at call
//  sites. The behaviour is documented saturation, never a crash.
//

/// Trap-free integer and floating-point helpers used throughout the package.
public enum Saturating {

    // MARK: - Integer arithmetic

    /// `a + b`, clamped to `Int.min ... Int.max` instead of trapping on overflow.
    @inlinable
    public static func add(_ a: Int, _ b: Int) -> Int {
        let (partial, overflow) = a.addingReportingOverflow(b)
        guard overflow else { return partial }
        // Overflow direction is determined by the sign of the addends: two
        // positives can only overflow upward, two negatives only downward.
        return b > 0 ? Int.max : Int.min
    }

    /// `a * b`, clamped to `Int.min ... Int.max` instead of trapping on overflow.
    @inlinable
    public static func multiply(_ a: Int, _ b: Int) -> Int {
        let (partial, overflow) = a.multipliedReportingOverflow(by: b)
        guard overflow else { return partial }
        // The sign of a true product is the XOR of the operand signs. Neither
        // operand can be zero here, because a product involving zero never
        // overflows.
        let negative = (a < 0) != (b < 0)
        return negative ? Int.min : Int.max
    }

    /// `a - b`, clamped instead of trapping.
    @inlinable
    public static func subtract(_ a: Int, _ b: Int) -> Int {
        let (partial, overflow) = a.subtractingReportingOverflow(b)
        guard overflow else { return partial }
        return b < 0 ? Int.max : Int.min
    }

    /// `a / b` with two trap cases removed: division by zero, and the single
    /// overflowing division `Int.min / -1`.
    ///
    /// - Returns: `fallback` when `b == 0`; `Int.max` for `Int.min / -1`
    ///   (whose true value, `-Int.min`, is one past the representable range).
    @inlinable
    public static func divide(_ a: Int, by b: Int, fallback: Int = 0) -> Int {
        guard b != 0 else { return fallback }
        let (partial, overflow) = a.dividedReportingOverflow(by: b)
        guard overflow else { return partial }
        return Int.max
    }

    // MARK: - Floating-point conversion

    /// The largest `Double` that is guaranteed to convert to `Int` without
    /// trapping, derived from `Int.max` rather than hardcoded as a 64-bit
    /// literal — `Int` is 32-bit on watchOS, where a hardcoded `9.2e18` would
    /// be a silent trap.
    ///
    /// `Double(Int.max)` rounds *up* past `Int.max` on 64-bit platforms (2^63
    /// is not representable as an `Int`, but is exactly representable as a
    /// `Double`), so the strict `<` comparison in ``clampedToInt(_:fallback:)``
    /// is load-bearing, not stylistic.
    @usableFromInline
    static let intConversionCeiling = Double(Int.max)

    @usableFromInline
    static let intConversionFloor = Double(Int.min)

    /// Converts a `Double` to an `Int` without trapping.
    ///
    /// `Int(someDouble)` traps on NaN, on ±infinity, and on any finite value
    /// outside the `Int` range. All three are reachable here: a judge can score
    /// `0.0 / 0.0`, a cost model can multiply by an unbounded token count.
    ///
    /// - Returns: `fallback` for NaN; the nearest representable bound for
    ///   out-of-range or infinite input; the truncated value otherwise.
    @inlinable
    public static func clampedToInt(_ value: Double, fallback: Int = 0) -> Int {
        guard !value.isNaN else { return fallback }
        guard value > intConversionFloor else { return Int.min }
        guard value < intConversionCeiling else { return Int.max }
        return Int(value)
    }

    /// `numerator / denominator` as a `Double`, returning `fallback` rather
    /// than ±infinity or NaN when the denominator is zero or either operand is
    /// not finite.
    @inlinable
    public static func ratio(_ numerator: Double, _ denominator: Double, fallback: Double = 0) -> Double {
        guard numerator.isFinite, denominator.isFinite, denominator != 0 else { return fallback }
        let result = numerator / denominator
        return result.isFinite ? result : fallback
    }

    /// `numerator / denominator` for integer counts, as a `Double` in `0...1`
    /// when the inputs are a subset count and a total.
    @inlinable
    public static func rate(_ numerator: Int, of denominator: Int) -> Double {
        guard denominator > 0 else { return 0 }
        return ratio(Double(numerator), Double(denominator))
    }

    /// Clamps a `Double` into `range`, mapping NaN to the lower bound.
    ///
    /// NaN maps to the lower bound deliberately: in this package every clamped
    /// quantity is a score or a probability where "unknown" must not be allowed
    /// to read as "good enough to pass".
    @inlinable
    public static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        guard !value.isNaN else { return range.lowerBound }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// Clamps an `Int` into `range`.
    @inlinable
    public static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
