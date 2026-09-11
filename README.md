# TrajectoryEvalGate

**Your agent eval passed 3 out of 3 runs. The 95% lower bound on that pass rate is 0.44.**

A system that fails more than half the time is entirely consistent with three
green runs. If your CI turns that into a checkmark, you have not built a quality
gate — you have built a very expensive coin flip with a nice badge.

`TrajectoryEvalGate` is the harness layer around agent evaluation: trajectory
contracts, confidence-bounded verdicts, sequential sampling under a budget,
flake-vs-regression classification, and judge calibration. Pure Swift, no
framework dependency, runs on Linux CI.

---

## Why this matters

Apple's Evaluations framework (iOS/macOS 27) gives iOS teams a way to grade a
tool-calling trajectory the way XCTest grades a function. That solves the
*measurement* problem. It does not solve the problem a lead actually has to
answer in a release meeting:

> The suite is green. How confident are we, and how many samples is that
> confidence worth?

A stochastic system needs a different gate design from a deterministic one, and
almost every eval harness in the wild is a deterministic-test harness with a
model bolted on. The specific failures that produces:

| What teams ship | What it actually does |
|---|---|
| "Run each case 3x, require all pass" | 3/3 has a 95% lower bound of **0.44**. The gate certifies nothing. |
| "Require a 95% pass rate, run 10 times" | A perfect 10/10 reaches a bound of **0.72**. The gate is red forever, mathematically. |
| "The observed rate cleared the bar" | 19/20 is a 0.95 observed rate and a **0.76** lower bound. It should not clear a 0.90 gate. |
| "Retry until it passes" | Converts a flake into a pass and a regression into a slow pass. |
| "A model judges the answer" | An uncalibrated judge that always says "pass" scores **90% raw agreement** on a 90%-passing set. |
| "Quorum of N, majority wins" | Cannot distinguish `PPPPPFFFFF` (something changed mid-sweep) from `PFPFPFPFPF` (genuine variance). |

Five of those six rows are a test in this package, and several are written as
*negative controls*: they construct the broken implementation and assert the
check rejects it. The exception is "retry until it passes" — there is nothing to
test, because the package offers no retry knob at all. That is the design
position: retrying destroys the sample the confidence bound is computed from,
so it is absent rather than discouraged.

---

## What's in it

### Trajectory contracts

`TrajectoryExpectation` is a contract over an agent's tool calls, not a snapshot
of them. `ExpectedStep` names a tool and constrains individual arguments with
`ArgumentMatcher`s (`stringHasPrefix`, `intBetween`, `oneOf`, `not`, `allOf`,
`absent`…), so a contract survives a prompt improvement and fails a behaviour
change.

Three ordering modes, each with a reason to exist:

- **`.exact`** — every call is consumed by a step. Use when an extra call *is*
  the regression: a duplicate `addToCart` is an extra order line.
- **`.subsequence`** — steps appear in order; unrelated calls are tolerated.
  Pins causality without pinning chattiness. The default.
- **`.unordered`** — steps are satisfied by distinct calls in any order. Use
  when the agent may legitimately parallelise independent lookups.

Plus two ordering-independent rules: `forbiddenTools` (a price question must not
reach the refund tool, however well the rest matched) and `maximumCalls` (a
loop guard).

### Two matching algorithms, and why greedy is wrong for both

`.exact` / `.subsequence` are a **dynamic program** over (step × call). A greedy
left-to-right walk breaks the moment a contract contains an optional step,
because it cannot know whether to spend the current call on the optional step or
save it for the required step behind it. `testOptionalStepDoesNotStealTheOnlyCallARequiredStepNeeds`
constructs exactly that trajectory — one call, an optional step then a required
step — and asserts it matches.

`.unordered` is **maximum bipartite matching** via Kuhn's augmenting-path
algorithm. Greedy is wrong here for the mirror-image reason: a permissive step
can consume the only call a pickier step could have used.
`testUnorderedMatchingReassignsAnAlreadyTakenCall` pins the trap — a permissive
`search` and a `search(page: 1)`, observed as page 1 then page 2 — and asserts
the four sub-facts that make greedy provably fail there.

Both are **bounded**. Step and call counts come from a dataset file and from a
model that can loop, so the search space is untrusted input. Over the ceiling,
the matcher reports `analysisBudgetExceeded` — a loud, never-passing verdict —
rather than allocating gigabytes inside a CI job.

### Confidence-bounded verdicts

Every pass/fail decision is made against the **Wilson score lower bound** on the
pass rate, never the point estimate.

Wilson rather than the textbook normal ("Wald") interval, because Wald is
degenerate exactly where eval gates live: at `s == n` its width is zero, so 3/3
would report a lower bound of 1.0 and every gate would pass on three lucky runs.
`testWilsonDoesNotCollapseWhereWaldWould` implements Wald in the test target and
runs the two side by side: for n = 3, 5, 20 and 10,000 it asserts Wald collapses
to exactly 1.0 while Wilson stays strictly below, and that the gap at n = 5 is
over 0.43 — not a rounding difference.

For a perfect run the bound simplifies to `n / (n + z²)`, which makes the
sample-size cost checkable by hand and impossible to argue with:

| Required lower bound | Consecutive passes needed (95% confidence) |
|---|---|
| 0.50 | 4 |
| 0.90 | 35 |
| 0.95 | 73 |
| 1.00 | no finite number |

### Feasibility: the misconfiguration nobody checks

`GatePolicy.feasibility` answers a question almost no team asks before merging
an eval config: *can this gate pass at all?*

A team that writes `requiredPassRateLowerBound: 0.95, maximumRuns: 10` has built
a gate that is red forever — and will conclude the feature is broken rather than
the policy. Surfacing that as a first-class value turns a silent
misconfiguration into a readable error, and the demo app renders it as a banner.

### Sequential sampling under a budget

`EvalGateRunner` stops sampling as soon as the verdict cannot change — either
the bound already clears the threshold, or even a perfect remainder cannot reach
it. On a metered backend that is real money.

The arithmetic is verified end to end: `testAPerfectCaseStopsExactlyAtTheRunCountTheMathPredicts`
asserts a flawless case stops at **exactly 35 runs**, tying the static
feasibility prediction to the runner's dynamic behaviour.

### Regression vs flake vs infrastructure

Three outcomes, deliberately distinct:

- **`fail`** — the bound did not clear the threshold. Someone should look at the
  change.
- **`inconclusive`** — the budget ran out, or the sample was dominated by
  transport errors. A build must not be marked broken because the eval
  infrastructure ran out of tokens, and it must not be marked green either.
- **`pass`** — with the evidence attached.

`StabilityVerdict` separates `stableFailing` (deterministic — points at the
change under review) from `flaky` (carries a Wilson bound, not a vibe), and
`alternationRate` separates a regime change mid-sweep from genuine per-run
variance. Drift against a recorded baseline is a two-proportion z test, checked
*separately* from the threshold: a case that fell from 99% to 93% still clears a
0.90 gate and is still the most interesting line in the report.

### Judge calibration

The rule: before a model-as-judge may fail a build, it has to agree with a human
on already-labelled cases — measured with **Cohen's kappa**, not raw agreement.

**Scope, stated precisely.** `JudgeCalibration` implements and tests that rule;
it does not wire it into the verdict. `EvalGateRunner` grades a run purely on
whether its trajectory satisfied the contract, and `BackendRunResult.judgeScore`
is carried but read by nothing in this package. Whether answer *quality* gates a
release is a product decision, so it belongs in the adapter — the package's job
is to make sure that when someone reaches for a judge, the calibration check is
already sitting there.

`testRubberStampJudgeIsRejectedDespiteHighRawAgreement` feeds in a deliberately
broken judge that answers "pass" to everything, against a 90%-passing set. It
scores 0.90 raw agreement, κ = 0, and misses **100%** of the failures the human
found. The calibration check rejects it. That is the negative control for the
headline claim of this section.

### The framework seam

```swift
public protocol EvaluationBackend: Sendable {
    var identifier: String { get }
    func run(_ evalCase: EvalCase, attempt: Int) async throws -> BackendRunResult
}
```

One protocol, one method.

**Exactly one conformer ships here: `DeterministicBackend`, a seeded fake.** The
adapters are the intended shape, not code in this repo. On Apple platforms an
adapter *would* conform by driving Apple's Evaluations framework against
Foundation Models (on-device or Private Cloud Compute) and translating the
result into a `Trajectory`; a remote model *would* conform by parsing tool-call
blocks out of an HTTP response. The gate cannot tell backends apart — which is
the point: the same policy and the same report apply whether the model is on the
device or across the network.

Keeping the framework outside the package is what lets the entire decision
layer be unit-tested on Linux, with no device and no network.

**One thing to know before writing that adapter.** This package's
`TrajectoryExpectation` and `ArgumentMatcher` collide by name with types Apple's
`Evaluations` framework exports. A file importing both modules must
module-qualify every use (`TrajectoryEvalGate.ArgumentMatcher` vs
`Evaluations.ArgumentMatcher`) or `typealias` one side at the top of the adapter.
The names are kept because they are the right domain names on this side of the
seam, and because an adapter is the only file that ever sees both — but it is
the first thing you would hit on integration, so it is stated here rather than
discovered.

---

## Design decisions, with the alternatives that were rejected

**Wilson over Wald, and over "just count."** Wald collapses at the boundary;
counting has no notion of confidence at all. Wilson costs about fifteen lines of
algebra and is the only one of the three that behaves at `s == n`, which is
where a healthy eval case lives.

**A statistic against a critical value, not a p-value.** Drift reports a z
statistic and the threshold it is compared against. A p-value would need a
normal-CDF approximation whose error nobody in the repo would ever check, and
the gate only ever asks the binary question.

**Rejected: retry-until-pass.** The single most common eval "fix." It converts
a flake into a pass and a regression into a slow pass, and destroys the sample
the confidence bound is computed from.

**Rejected: `@Observable` in the UI layer.** It would raise the deployment floor
to iOS 17 for a property-wrapper ergonomics win. A library should not make that
trade on a consumer app's behalf; the view model is an `ObservableObject`.

**Rejected: `Hasher` for the deterministic backend's seed.** Swift's `Hasher` is
seeded per process, so `"case-1".hashValue` differs between runs of the same
binary. A backend built on it is reproducible within a process and different on
every CI run — the exact failure it exists to prevent, and one that a test
hashing the same string twice in one process would never catch. FNV-1a is used
instead, and the test asserts against **precomputed constants**.

**Rejected: trapping arithmetic.** An eval gate reads numbers it did not produce
— run counts from a CI matrix, costs from a vendor response, scores from a
judge. `Int(Double.nan)`, `%` by zero, `Int.min / -1` and `+`/`*` overflow all
trap, and a trap inside a CI gate is indistinguishable from an infrastructure
outage. Everything routes through `Saturating`, whose behaviour is documented
saturation. The `Int`-range ceiling is derived from `Int.max` rather than
hardcoded, because `Int` is 32-bit on watchOS.

**An empty sweep is not green.** `GateReport.isGreen` is `false` for zero cases.
`allSatisfy` on an empty array is `true`, and the most common way an eval gate
becomes decorative is a dataset that silently fails to load.

**Actor isolation is not enough for the budget ledger.** `evaluate` suspends at
every `await backend.run(...)`, and another task can enter the actor during that
suspension. A naive `if spent < limit { await run(); spent += 1 }` lets N
concurrent sweeps read the same pre-increment value and overspend by N billed
model calls. The invariant here is that **no read-modify-write of the ledger
spans a suspension point**: `reserveRun()` checks and decrements in one
synchronous body. `testConcurrentSweepsCannotOverspendTheBudget` runs two sweeps
against a shared 25-run budget and asserts exactly 25 runs were spent.

---

## Using it

```swift
.package(url: "https://github.com/rajatslakhina/trajectory-eval-gate-kit.git", from: "1.1.0")
```

```swift
import Foundation
import TrajectoryEvalGate

let contract = TrajectoryExpectation(
    steps: [
        ExpectedStep(toolName: "scanBarcode"),
        ExpectedStep(toolName: "lookUpProduct", arguments: ["sku": .stringHasPrefix("THD-")])
    ],
    ordering: .subsequence,
    forbiddenTools: ["refundOrder"],
    maximumCalls: 8
)

let cases = [EvalCase(id: "price-check", prompt: "What does this cost?", expectation: contract)]
let policy = GatePolicy.standard          // 20–60 runs, 0.90 lower bound

// Catch the red-forever config. Deliberately not `precondition`: this package
// argues that a trap inside a CI gate is indistinguishable from an
// infrastructure outage, and the sample code should not install the failure
// mode the library spends a file avoiding.
guard case .achievable = policy.feasibility else {
    FileHandle.standardError.write(Data("eval policy can never pass: \(policy.feasibility)\n".utf8))
    exit(2)
}

let runner = EvalGateRunner(
    backend: myFoundationModelsAdapter,          // or Fixtures.demoBackend()
    budget: .sufficient(for: policy, caseCount: cases.count, tokensPerRun: 800)
)
let report = await runner.evaluate(cases: cases, policy: policy)

print(report.headline)
exit(report.isGreen ? 0 : 1)
```

## Running the tests

```bash
swift build -Xswiftc -warnings-as-errors
swift test
```

## Verification

Two buckets, because "the suite is green" and "someone ran the app" are not the
same claim.

**Verified — this actually happened.**

- **Clean build** (`rm -rf .build` first, so this is a real from-scratch compile
  of every file, not an up-to-date no-op) with `swift build -Xswiftc
  -warnings-as-errors` *and* `swift build --build-tests -Xswiftc
  -warnings-as-errors` on Swift 6.0.3, Linux aarch64. **Zero warnings.**
- **82 XCTest cases, 0 failures.** Coverage includes every trapping-arithmetic
  edge case, the matcher's search-budget ceiling, the untrusted-nesting stack
  guards on both the matcher and the value tree, empty/boundary trajectories,
  actor-reentrancy under two concurrent sweeps on one budget, and the negative
  controls named above.
- **Statistical expectations are precomputed out-of-band**, not produced by the
  code under test, and the deterministic backend's outcome sequence is pinned to
  a value recorded in an earlier process. A test that computes its own
  expectation with the code it is testing asserts only that the code is
  deterministic.

- **CI is green on both jobs.** The Linux job reproduces the clean build and the
  test run in a container; the `macos-15` job compiles `TrajectoryEvalGateUI`
  for `generic/platform=iOS Simulator`. That second job is what covers
  `EvalGateDashboardView.swift`, which sits entirely behind
  `#if canImport(SwiftUI)` and is therefore invisible to the Linux build — so
  the SwiftUI layer is compiled by CI, not merely written. Read the live result
  on the
  [Actions tab](https://github.com/rajatslakhina/trajectory-eval-gate-kit/actions)
  rather than trusting this paragraph; a run ID quoted here would go stale on
  the next commit.
- `generic/platform=iOS Simulator` deliberately, never a named device: pinning
  to `name=iPhone 16` ties the job to whichever simulator runtimes happen to be
  installed on that day's runner image, and a compile check needs no device to
  exist.

**Not established.**

- **The app was never launched, and no screenshots exist.** Requesting control
  of the Simulator returned, verbatim: *"Computer-use access to \"Simulator\"
  can't be approved during a scheduled run."* "Compiles for a Simulator" and
  "ran on a Simulator" are different claims, and neither is being made from the
  other.

## Demo app

**Demo app:** [trajectory-eval-gate-demo-app](https://github.com/rajatslakhina/trajectory-eval-gate-demo-app)
— a SwiftUI app that consumes this package as a version-pinned remote
dependency and renders a sweep: the feasibility banner, a bound-vs-threshold bar
per case, early stopping, and the three-way `pass` / `fail` / `inconclusive`
verdict.

## Licence

MIT.
