// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DraftFrame",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
    ],
    targets: [
        .target(
            name: "DraftFrameKit",
            dependencies: ["SwiftTerm"],
            path: "Sources/DraftFrameKit",
            swiftSettings: [
                // Surface data-race hazards as warnings (Swift 5 language
                // mode never promotes these to errors). Inventory for the
                // incremental actor migration; see git history for context.
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "DraftFrame",
            dependencies: ["DraftFrameKit", "SwiftTerm"],
            path: "Sources/DraftFrame",
            exclude: ["AppIcon.png"]
        ),
        .executableTarget(
            name: "dfqa",
            path: "Sources/dfqa"
        ),
        .testTarget(
            name: "DraftFrameTests",
            dependencies: ["DraftFrameKit"],
            path: "Tests/DraftFrameTests"
        ),
    ]
)
