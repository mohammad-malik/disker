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
        .executableTarget(
            name: "Disker",
            dependencies: ["DiskerCore"],
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        ),
        // Headless harness for benchmarking and cross-checking the scanner against `du`.
        // Earns its place while SwiftUI Previews are unavailable: scanner behaviour can be
        // exercised without launching the GUI.
        .executableTarget(name: "diskerctl", dependencies: ["DiskerCore"]),
        .testTarget(name: "DiskerCoreTests", dependencies: ["DiskerCore"]),
    ]
)
