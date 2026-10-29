// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Disker",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Disker", targets: ["Disker"]),
        .executable(name: "diskerctl", targets: ["diskerctl"]),
        .library(name: "DiskerCore", targets: ["DiskerCore"]),
    ],
    targets: [
        // Pure model + scanning logic. No SwiftUI, so it stays unit-testable
        // and benchmarkable headlessly — which matters while Previews are unavailable.
        .target(name: "DiskerCore"),
        // RemoveMacAI, vendored verbatim by Tools/sync-removemacai.sh. Upstream builds in the
        // Swift 5 language mode and ships its own entry point, which Disker replaces with
        // `DebloatBridge.swift`; nothing under `Upstream/` is edited here.
        //
        // Left out: the command-line entry point and its self-test, which only it reaches.
        // The self-test uses helpers that live in main.swift, so the two go together; it still
        // runs, against upstream's own build of the same files, in
        // Tools/check-removemacai.sh.
        .target(name: "UAF", cSettings: [.unsafeFlags(["-fobjc-arc"])]),
        .target(
            name: "RemoveMacAIKit",
            dependencies: ["UAF"],
            exclude: [
                "Upstream/main.swift", "Upstream/SelfTest.swift", "Upstream/LICENSE",
                "Upstream/THIRD-PARTY-NOTICES.md", "Upstream/UPSTREAM",
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Disker",
            dependencies: ["DiskerCore", "RemoveMacAIKit"],
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        ),
        // Headless harness for benchmarking and cross-checking the scanner against `du`.
        // Earns its place while SwiftUI Previews are unavailable: scanner behaviour can be
        // exercised without launching the GUI.
        .executableTarget(name: "diskerctl", dependencies: ["DiskerCore"]),
        .testTarget(name: "DiskerCoreTests", dependencies: ["DiskerCore"]),
    ]
)
