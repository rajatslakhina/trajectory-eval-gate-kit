//
//  Fixtures.swift
//  TrajectoryEvalGate
//
//  A small, realistic dataset shipped with the package.
//
//  It is deliberately part of the library rather than the test target: the demo
//  app renders it, the tests assert against it, and a reader who wants to know
//  what a trajectory contract looks like in practice can read one file instead
//  of assembling it from doc comments. The scenario is a retail shopping
//  assistant — barcode scan, OCR of a shelf label, product lookup, add to cart
//  — with a refund tool that must never be reachable from a price question.
//

/// The tool names used by the shipped fixtures.
public enum DemoTool {
    public static let scanBarcode = "scanBarcode"
    public static let runOCR = "runOCR"
    public static let lookUpProduct = "lookUpProduct"
    public static let addToCart = "addToCart"
    /// Present in the tool registry, forbidden in every contract below. A
    /// refund is the canonical "the agent must not be able to reach this from a
    /// price question" side effect.
    public static let refundOrder = "refundOrder"
}

/// Ready-made cases, contracts, and backend behaviours.
public enum Fixtures {

    // MARK: - Trajectory contracts

    /// Scan a barcode, then look the SKU up. Extra chatter is tolerated
    /// (`.subsequence`); a refund is not.
    public static var barcodePriceCheck: TrajectoryExpectation {
        TrajectoryExpectation(
            steps: [
                ExpectedStep(toolName: DemoTool.scanBarcode, label: "Scan the barcode"),
                ExpectedStep(
                    toolName: DemoTool.lookUpProduct,
                    arguments: ["sku": .stringHasPrefix("THD-")],
                    label: "Look up the SKU"
                )
            ],
            ordering: .subsequence,
            forbiddenTools: [DemoTool.refundOrder],
            maximumCalls: 8
        )
    }

    /// OCR is optional — the agent may read the label from the photo or skip
    /// straight to a lookup if it recognises the product. This is the contract
    /// that makes greedy matching wrong and the DP necessary.
    public static var shelfLabelPriceCheck: TrajectoryExpectation {
        TrajectoryExpectation(
            steps: [
                ExpectedStep(toolName: DemoTool.runOCR, isOptional: true, label: "Read the shelf label (optional)"),
                ExpectedStep(
                    toolName: DemoTool.lookUpProduct,
                    arguments: ["sku": .stringHasPrefix("THD-")],
                    label: "Look up the SKU"
                )
            ],
            ordering: .subsequence,
            forbiddenTools: [DemoTool.refundOrder],
            maximumCalls: 8
        )
    }

    /// Look up, then add exactly one to ten units. `.exact` because an extra
    /// `addToCart` here is a duplicate order line, not chatter.
    public static var addToCartFlow: TrajectoryExpectation {
        TrajectoryExpectation(
            steps: [
                ExpectedStep(
                    toolName: DemoTool.lookUpProduct,
                    arguments: ["sku": .stringHasPrefix("THD-")],
                    label: "Look up the SKU"
                ),
                ExpectedStep(
                    toolName: DemoTool.addToCart,
                    arguments: [
                        "sku": .stringHasPrefix("THD-"),
                        "quantity": .intBetween(1, 10)
                    ],
                    label: "Add to cart"
                )
            ],
            ordering: .exact,
            forbiddenTools: [DemoTool.refundOrder],
            maximumCalls: 2
        )
    }

    // MARK: - Trajectories

    public static func call(_ name: String, _ arguments: [String: ArgumentValue] = [:]) -> ToolCall {
        ToolCall(name: name, arguments: arguments)
    }

    public static var barcodeGolden: Trajectory {
        Trajectory(
            calls: [
                call(DemoTool.scanBarcode, ["image": .string("frame-0")]),
                call(DemoTool.lookUpProduct, ["sku": .string("THD-100482")])
            ],
            finalAnswer: "That's the 18V cordless drill, $129.00."
        )
    }

    /// The realistic regression: the model answers from memory and never calls
    /// the lookup tool, so the price it quotes is whatever was in its weights.
    public static var barcodeDegraded: Trajectory {
        Trajectory(
            calls: [call(DemoTool.scanBarcode, ["image": .string("frame-0")])],
            finalAnswer: "That's the 18V cordless drill, about $120."
        )
    }

    public static var shelfLabelGolden: Trajectory {
        Trajectory(
            calls: [
                call(DemoTool.runOCR, ["image": .string("shelf-7")]),
                call(DemoTool.lookUpProduct, ["sku": .string("THD-773100")])
            ],
            finalAnswer: "$42.98 for the two-pack."
        )
    }

    /// Passes despite skipping the optional OCR step — included so the demo can
    /// show that an optional step really is optional.
    public static var shelfLabelGoldenWithoutOCR: Trajectory {
        Trajectory(
            calls: [call(DemoTool.lookUpProduct, ["sku": .string("THD-773100")])],
            finalAnswer: "$42.98 for the two-pack."
        )
    }

    /// The SKU came out of the model rather than the label: right shape, wrong
    /// namespace. This is the failure an `.equals` matcher would have caught by
    /// accident and a `.any` matcher would have missed entirely.
    public static var shelfLabelDegraded: Trajectory {
        Trajectory(
            calls: [
                call(DemoTool.runOCR, ["image": .string("shelf-7")]),
                call(DemoTool.lookUpProduct, ["sku": .string("SKU-773100")])
            ],
            finalAnswer: "$42.98 for the two-pack."
        )
    }

    public static var addToCartGolden: Trajectory {
        Trajectory(
            calls: [
                call(DemoTool.lookUpProduct, ["sku": .string("THD-100482")]),
                call(DemoTool.addToCart, ["sku": .string("THD-100482"), "quantity": .int(2)])
            ],
            finalAnswer: "Added two to your cart."
        )
    }

    /// The duplicate-add regression: two `addToCart` calls, which `.exact`
    /// catches and `.subsequence` would have let through.
    public static var addToCartDegraded: Trajectory {
        Trajectory(
            calls: [
                call(DemoTool.lookUpProduct, ["sku": .string("THD-100482")]),
                call(DemoTool.addToCart, ["sku": .string("THD-100482"), "quantity": .int(2)]),
                call(DemoTool.addToCart, ["sku": .string("THD-100482"), "quantity": .int(2)])
            ],
            finalAnswer: "Added two to your cart."
        )
    }

    /// The one that should stop a release: a price question that reaches the
    /// refund tool.
    public static var forbiddenToolTrajectory: Trajectory {
        Trajectory(
            calls: [
                call(DemoTool.scanBarcode, ["image": .string("frame-0")]),
                call(DemoTool.lookUpProduct, ["sku": .string("THD-100482")]),
                call(DemoTool.refundOrder, ["orderID": .string("A-99120")])
            ],
            finalAnswer: "I've refunded that for you."
        )
    }

    // MARK: - Cases

    public static let barcodeCaseID = "price-check-barcode"
    public static let shelfLabelCaseID = "price-check-shelf-label"
    public static let addToCartCaseID = "add-to-cart"

    /// The three-case dataset the demo app runs.
    ///
    /// Baselines are the previous sweep's recorded numbers, so the demo can
    /// show drift detection doing something rather than always reporting "no
    /// baseline".
    public static var demoCases: [EvalCase] {
        [
            EvalCase(
                id: barcodeCaseID,
                prompt: "What does this cost?",
                expectation: barcodePriceCheck,
                baseline: BaselineRecord(passes: 58, runs: 60)
            ),
            EvalCase(
                id: shelfLabelCaseID,
                prompt: "Price for the item on this shelf label?",
                expectation: shelfLabelPriceCheck,
                baseline: BaselineRecord(passes: 57, runs: 60)
            ),
            EvalCase(
                id: addToCartCaseID,
                prompt: "Add two of these to my cart.",
                expectation: addToCartFlow,
                baseline: BaselineRecord(passes: 59, runs: 60)
            )
        ]
    }

    /// Backend behaviours describing a plausible regression: the barcode case
    /// is healthy, the shelf-label case has quietly dropped to a rate that
    /// clears a naive majority vote but not a 90% confidence bound, and the
    /// add-to-cart case is fine but occasionally flakes on transport.
    public static func demoBehaviours(shelfLabelPassProbability: Double = 0.72) -> [String: CaseBehaviour] {
        [
            barcodeCaseID: CaseBehaviour(
                golden: barcodeGolden,
                degraded: barcodeDegraded,
                passProbability: 0.98,
                tokensPerRun: 420
            ),
            shelfLabelCaseID: CaseBehaviour(
                golden: shelfLabelGolden,
                degraded: shelfLabelDegraded,
                passProbability: shelfLabelPassProbability,
                tokensPerRun: 610
            ),
            addToCartCaseID: CaseBehaviour(
                golden: addToCartGolden,
                degraded: addToCartDegraded,
                passProbability: 0.99,
                errorProbability: 0.05,
                tokensPerRun: 380
            )
        ]
    }

    /// A ready-to-run backend for the demo app and the tests.
    public static func demoBackend(
        seed: UInt64 = 0xD15E_A5E5,
        shelfLabelPassProbability: Double = 0.72
    ) -> DeterministicBackend {
        DeterministicBackend(
            identifier: "deterministic-fake",
            seed: seed,
            behaviours: demoBehaviours(shelfLabelPassProbability: shelfLabelPassProbability)
        )
    }
}
