//
//  ArgumentMatcher.swift
//  TrajectoryEvalGate
//
//  The expected side of the contract, at argument granularity.
//

/// A predicate over a single tool argument.
///
/// The design constraint is that a golden trajectory has to survive changes
/// that do not matter. Asserting `query == "cordless drill 18v"` makes the
/// suite fail the first time someone improves the prompt; asserting
/// `.stringContains("drill")` fails only when the agent stops searching for a
/// drill. Matchers are how a trajectory contract stays a contract instead of
/// becoming a snapshot test.
public indirect enum ArgumentMatcher: Sendable, Equatable {
    /// Matches any present value, including `null`.
    case any
    /// Exact structural equality against a literal.
    case equals(ArgumentValue)
    /// Equality against any one of several accepted literals.
    case oneOf([ArgumentValue])
    /// Substring containment; applies only to `.string` values.
    case stringContains(String, caseSensitive: Bool = true)
    /// Prefix match; applies only to `.string` values.
    case stringHasPrefix(String)
    /// Inclusive integer bounds; applies only to `.int` values.
    case intBetween(Int, Int)
    /// Inclusive floating-point bounds; applies only to `.double` values.
    /// NaN never matches, and non-finite bounds are rejected as a malformed
    /// matcher rather than silently accepting everything.
    case doubleBetween(Double, Double)
    /// The key must not appear in the call's arguments at all.
    case absent
    /// The key must appear, with any value.
    case present
    /// Logical negation. `.not(.absent)` is equivalent to `.present`.
    case not(ArgumentMatcher)
    /// Conjunction; an empty list matches (vacuous truth), which is why
    /// ``ArgumentMatcher/allOf(_:)`` should not be built from a filtered list
    /// without checking the result is non-empty.
    case allOf([ArgumentMatcher])
    /// Disjunction; an empty list never matches.
    case anyOf([ArgumentMatcher])
}

/// Why a single argument did or did not match.
public struct ArgumentMismatch: Sendable, Equatable {
    public let key: String
    public let matcher: ArgumentMatcher
    public let actual: ArgumentValue?
    public let reason: String

    public init(key: String, matcher: ArgumentMatcher, actual: ArgumentValue?, reason: String) {
        self.key = key
        self.matcher = matcher
        self.actual = actual
        self.reason = reason
    }

    public var description: String {
        let actualText = actual.map(\.description) ?? "<absent>"
        return "argument `\(key)`: \(reason) (actual: \(actualText))"
    }
}

extension ArgumentMatcher {

    /// Hard ceiling on `.not` / `.allOf` / `.anyOf` nesting.
    ///
    /// Matchers can be decoded from a dataset file, which means their depth is
    /// untrusted input to a recursive evaluator. Without a ceiling, a 100k-deep
    /// `.not` chain overflows the stack — and stack overflow is a crash, not a
    /// catchable error, so it would take the whole CI job down rather than
    /// failing one case. Exceeding the ceiling is reported as a *non-match with
    /// a reason*, which surfaces as a gate failure a human can read.
    public static let maximumNestingDepth = 32

    /// Evaluates this matcher against the value found (or not found) at `key`.
    ///
    /// - Parameter value: `nil` means the key was absent from the call.
    /// - Returns: `nil` on a match, or the mismatch to report.
    public func evaluate(key: String, value: ArgumentValue?) -> ArgumentMismatch? {
        switch evaluate(value: value, depth: 0) {
        case .matched:
            return nil
        case .mismatch(let reason):
            return ArgumentMismatch(key: key, matcher: self, actual: value, reason: reason)
        }
    }

    enum Outcome {
        case matched
        case mismatch(String)
    }

    func evaluate(value: ArgumentValue?, depth: Int) -> Outcome {
        guard depth <= Self.maximumNestingDepth else {
            return .mismatch("matcher nesting exceeded \(Self.maximumNestingDepth) levels; treated as non-matching")
        }

        switch self {
        case .absent:
            return value == nil ? .matched : .mismatch("expected the argument to be absent")

        case .present:
            return value != nil ? .matched : .mismatch("expected the argument to be present")

        case .not(let inner):
            switch inner.evaluate(value: value, depth: depth + 1) {
            case .matched:
                return .mismatch("expected NOT to match \(inner)")
            case .mismatch:
                return .matched
            }

        case .allOf(let matchers):
            for matcher in matchers {
                if case .mismatch(let reason) = matcher.evaluate(value: value, depth: depth + 1) {
                    return .mismatch(reason)
                }
            }
            return .matched

        case .anyOf(let matchers):
            guard !matchers.isEmpty else {
                return .mismatch("anyOf with no alternatives never matches")
            }
            for matcher in matchers {
                if case .matched = matcher.evaluate(value: value, depth: depth + 1) {
                    return .matched
                }
            }
            return .mismatch("matched none of \(matchers.count) alternatives")

        default:
            // Every remaining case requires a present value; collapsing the
            // nil check here keeps each leaf case from repeating it.
            guard let value else {
                return .mismatch("expected the argument to be present")
            }
            return evaluateLeaf(value: value)
        }
    }

    private func evaluateLeaf(value: ArgumentValue) -> Outcome {
        switch self {
        case .any:
            return .matched

        case .equals(let expected):
            return value == expected ? .matched : .mismatch("expected \(expected)")

        case .oneOf(let accepted):
            guard !accepted.isEmpty else {
                return .mismatch("oneOf with no accepted values never matches")
            }
            return accepted.contains(value)
                ? .matched
                : .mismatch("expected one of \(accepted.map(\.description).joined(separator: ", "))")

        case .stringContains(let needle, let caseSensitive):
            guard case .string(let haystack) = value else {
                return .mismatch("expected a string value")
            }
            guard !needle.isEmpty else {
                // An empty needle is contained in every string, which makes the
                // assertion vacuous. Refusing it stops a typo'd dataset from
                // reading as passing coverage.
                return .mismatch("stringContains was given an empty needle, which would assert nothing")
            }
            let found = caseSensitive
                ? haystack.contains(needle)
                : haystack.lowercased().contains(needle.lowercased())
            return found ? .matched : .mismatch("expected to contain \"\(needle)\"")

        case .stringHasPrefix(let prefix):
            guard case .string(let text) = value else {
                return .mismatch("expected a string value")
            }
            guard !prefix.isEmpty else {
                return .mismatch("stringHasPrefix was given an empty prefix, which would assert nothing")
            }
            return text.hasPrefix(prefix) ? .matched : .mismatch("expected prefix \"\(prefix)\"")

        case .intBetween(let lower, let upper):
            guard lower <= upper else {
                return .mismatch("intBetween has an inverted range (\(lower) > \(upper))")
            }
            guard case .int(let actual) = value else {
                return .mismatch("expected an integer value")
            }
            return (lower...upper).contains(actual)
                ? .matched
                : .mismatch("expected an integer in \(lower)...\(upper)")

        case .doubleBetween(let lower, let upper):
            guard lower.isFinite, upper.isFinite else {
                return .mismatch("doubleBetween requires finite bounds")
            }
            guard lower <= upper else {
                return .mismatch("doubleBetween has an inverted range (\(lower) > \(upper))")
            }
            guard case .double(let actual) = value else {
                return .mismatch("expected a floating-point value")
            }
            guard actual.isFinite else {
                // Reachable: a judge or a tool can emit NaN or infinity. A
                // range comparison against NaN is always false, so this returns
                // the same verdict either way — but with a reason that names
                // the real problem instead of "out of range".
                return .mismatch("value is not finite (\(actual))")
            }
            return (actual >= lower && actual <= upper)
                ? .matched
                : .mismatch("expected a value in \(lower)...\(upper)")

        case .absent, .present, .not, .allOf, .anyOf:
            // Unreachable: handled before `evaluateLeaf` is called. Returning a
            // mismatch rather than trapping keeps the crash-free guarantee
            // total even if a future case is added to the enum and this switch
            // is not updated.
            return .mismatch("internal: composite matcher reached the leaf evaluator")
        }
    }
}
