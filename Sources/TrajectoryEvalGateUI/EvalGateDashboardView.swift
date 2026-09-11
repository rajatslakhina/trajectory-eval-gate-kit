//
//  EvalGateDashboardView.swift
//  TrajectoryEvalGateUI
//
//  A SwiftUI view over a `GateReport`.
//
//  The whole file is behind `#if canImport(SwiftUI)` so the package still
//  builds — and its tests still run — on Linux CI, where the core logic is
//  fully exercised and SwiftUI does not exist.
//

#if canImport(SwiftUI)
import SwiftUI
import TrajectoryEvalGate

/// Drives a sweep and publishes its report.
///
/// `ObservableObject` rather than `@Observable` because the package's
/// deployment floor is iOS 16 / macOS 13, and the Observation framework needs
/// iOS 17. Raising the floor for a property-wrapper ergonomics win is exactly
/// the trade a library should not make on a consumer app's behalf.
@MainActor
public final class EvalGateViewModel: ObservableObject {

    @Published public private(set) var report: GateReport?
    @Published public private(set) var isRunning = false

    public let cases: [EvalCase]
    public let policy: GatePolicy
    private let makeBackend: @Sendable () -> DeterministicBackend

    public init(
        cases: [EvalCase] = Fixtures.demoCases,
        policy: GatePolicy = .standard,
        makeBackend: @escaping @Sendable () -> DeterministicBackend = { Fixtures.demoBackend() }
    ) {
        self.cases = cases
        self.policy = policy
        self.makeBackend = makeBackend
    }

    /// The budget derived from the policy, so a sweep is never cut short by a
    /// number nobody computed.
    public var budget: EvalBudget {
        EvalBudget.sufficient(for: policy, caseCount: cases.count, tokensPerRun: 800)
    }

    public func runSweep() async {
        guard !isRunning else { return }
        isRunning = true
        // `defer` rather than a trailing assignment: an error thrown by a real
        // backend adapter must not leave the button spinning forever.
        defer { isRunning = false }

        let runner = EvalGateRunner(backend: makeBackend(), budget: budget)
        let produced = await runner.evaluate(cases: cases, policy: policy)
        report = produced
    }
}

/// The demo dashboard: policy feasibility up top, then one row per case.
///
/// `@MainActor` on the type, not just on `body`: the initialiser constructs a
/// `@MainActor` view model, and under Swift 6's strict concurrency a
/// non-isolated `init` doing that is a hard error rather than a warning.
@MainActor
public struct EvalGateDashboardView: View {

    @StateObject private var model: EvalGateViewModel

    public init(cases: [EvalCase] = Fixtures.demoCases, policy: GatePolicy = .standard) {
        _model = StateObject(wrappedValue: EvalGateViewModel(cases: cases, policy: policy))
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    policyCard
                    feasibilityCard
                    runButton
                    if let report = model.report {
                        headlineCard(report)
                        ForEach(report.results) { result in
                            CaseRow(result: result, threshold: model.policy.requiredPassRateLowerBound)
                        }
                    } else {
                        emptyState
                    }
                }
                .padding(16)
            }
            .navigationTitle("Eval Gate")
        }
    }

    // MARK: - Sections

    private var policyCard: some View {
        Card(title: "Policy") {
            LabeledLine("Runs per case", "\(model.policy.minimumRuns)–\(model.policy.maximumRuns)")
            LabeledLine("Required lower bound", percent(model.policy.requiredPassRateLowerBound))
            LabeledLine("Confidence", "z = \(model.policy.confidenceZ)")
            Text("The verdict is made against the Wilson lower bound on the pass rate, not the observed rate. 3-for-3 is a lower bound of 0.44.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var feasibilityCard: some View {
        switch model.policy.feasibility {
        case .achievable(let needed):
            Card(title: "Feasibility") {
                Label("Achievable", systemImage: "checkmark.seal")
                    .foregroundStyle(.green)
                Text("Needs at least \(needed) passing runs to clear \(percent(model.policy.requiredPassRateLowerBound)); the ceiling is \(model.policy.maximumRuns).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .unachievable(let best, let runsNeeded):
            Card(title: "Feasibility") {
                Label("This gate can never pass", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(unachievableExplanation(best: best, runsNeeded: runsNeeded))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func unachievableExplanation(best: Double, runsNeeded: Int?) -> String {
        let ceiling = "A perfect \(model.policy.maximumRuns)-for-\(model.policy.maximumRuns) sweep reaches a lower bound of only \(percent(best))."
        guard let runsNeeded else {
            return ceiling + " No finite number of runs reaches this threshold."
        }
        return ceiling + " Clearing \(percent(model.policy.requiredPassRateLowerBound)) needs \(runsNeeded) runs."
    }

    private var runButton: some View {
        Button {
            Task { await model.runSweep() }
        } label: {
            HStack {
                if model.isRunning { ProgressView() }
                Text(model.isRunning ? "Sampling…" : "Run the gate")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.isRunning)
    }

    private var emptyState: some View {
        Card(title: "\(model.cases.count) cases loaded") {
            ForEach(model.cases) { evalCase in
                VStack(alignment: .leading, spacing: 2) {
                    Text(evalCase.id).font(.subheadline.weight(.medium))
                    Text(evalCase.prompt).font(.footnote).foregroundStyle(.secondary)
                    Text(contractSummary(evalCase.expectation))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Tap “Run the gate” to sample each case against its trajectory contract.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func contractSummary(_ expectation: TrajectoryExpectation) -> String {
        let steps = expectation.steps
            .map { $0.isOptional ? "\($0.toolName)?" : $0.toolName }
            .joined(separator: " → ")
        let forbidden = expectation.forbiddenTools.sorted().joined(separator: ", ")
        let suffix = forbidden.isEmpty ? "" : " · forbidden: \(forbidden)"
        return "\(expectation.ordering.rawValue): \(steps)\(suffix)"
    }

    private func headlineCard(_ report: GateReport) -> some View {
        Card(title: report.isGreen ? "Gate passed" : "Gate failed") {
            Label(
                report.isGreen ? "Release may proceed" : "Release blocked",
                systemImage: report.isGreen ? "checkmark.circle.fill" : "xmark.octagon.fill"
            )
            .foregroundStyle(report.isGreen ? Color.green : Color.red)
            Text(report.headline)
                .font(.footnote)
                .foregroundStyle(.secondary)
            LabeledLine("Backend", report.backendIdentifier)
            LabeledLine("Runs spent", "\(report.runsSpent)")
            LabeledLine("Tokens spent", "\(report.tokensSpent)")
        }
    }

    private func percent(_ value: Double) -> String {
        let scaled = (value * 1000).rounded() / 10
        return "\(scaled)%"
    }
}

// MARK: - Rows

private struct CaseRow: View {
    let result: CaseResult
    let threshold: Double

    var body: some View {
        Card(title: result.id) {
            HStack {
                Text(verdictText).font(.subheadline.weight(.semibold)).foregroundStyle(verdictColor)
                Spacer()
                Text("\(result.evidence.passes)/\(result.evidence.runs)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            BoundBar(lowerBound: result.evidence.passRateLowerBound, threshold: threshold)

            LabeledLine("Observed rate", format(result.evidence.observedPassRate))
            LabeledLine("Lower bound", format(result.evidence.passRateLowerBound))
            LabeledLine("Required", format(threshold))
            LabeledLine("Stability", stabilityText)

            // Grouped, not inlined. `ViewBuilder` tops out at ten children;
            // inlining the four conditionals would put this `Card` at exactly
            // ten, leaving no room to add a row without an unhelpful
            // type-check error. Extracted, the card holds seven.
            conditionalDetail
        }
    }

    @ViewBuilder
    private var conditionalDetail: some View {
        if result.evidence.stoppedEarly {
            LabeledLine("Sampling", "stopped early — verdict already settled")
        }
        if result.errorCount > 0 {
            LabeledLine("Errored runs", "\(result.errorCount)")
        }
        if let drifted = result.driftIsSignificant {
            LabeledLine("Drift vs baseline", drifted ? "significant" : "within noise")
        }
        if let diff = result.representativeDiff {
            Text(diff.summary)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var verdictText: String {
        switch result.outcome {
        case .pass: return "PASS"
        case .fail(let reason): return "FAIL — \(reason)"
        case .inconclusive(let reason): return "INCONCLUSIVE — \(reason)"
        }
    }

    private var verdictColor: Color {
        switch result.outcome {
        case .pass: return .green
        case .fail: return .red
        case .inconclusive: return .orange
        }
    }

    private var stabilityText: String {
        switch result.stability {
        case .stablePassing(let runs):
            return "stable across \(runs) runs"
        case .stableFailing(let runs):
            return "fails every run (\(runs)) — deterministic regression"
        case .flaky(let passes, let runs, let lowerBound):
            let alternation = (result.alternationRate * 100).rounded() / 100
            return "flaky \(passes)/\(runs), bound \(format(lowerBound)), alternation \(alternation)"
        case .insufficientData(let runs, let required):
            return "only \(runs) of \(required) required runs"
        }
    }

    private func format(_ value: Double) -> String {
        let scaled = (value * 1000).rounded() / 1000
        return "\(scaled)"
    }
}

/// A two-segment bar: achieved lower bound against the required threshold.
private struct BoundBar: View {
    let lowerBound: Double
    let threshold: Double

    var body: some View {
        GeometryReader { geometry in
            let width = max(0, geometry.size.width)
            // Clamped before multiplying: a NaN width would propagate into
            // layout, and SwiftUI's response to a NaN frame is undefined.
            let filled = width * clamped(lowerBound)
            let mark = width * clamped(threshold)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(lowerBound >= threshold ? Color.green : Color.red)
                    .frame(width: filled)
                Rectangle()
                    .fill(Color.primary.opacity(0.55))
                    .frame(width: 2)
                    .offset(x: max(0, mark - 1))
            }
        }
        .frame(height: 10)
        .accessibilityLabel("Pass-rate lower bound \(clamped(lowerBound)) against a threshold of \(clamped(threshold))")
    }

    private func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

// MARK: - Small building blocks

private struct Card<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.secondary.opacity(0.10))
        )
    }
}

private struct LabeledLine: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.footnote).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).font(.footnote.monospacedDigit()).multilineTextAlignment(.trailing)
        }
    }
}

#endif
