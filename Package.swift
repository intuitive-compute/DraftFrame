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
            path: "Sources/DraftFrameKit"
        ),
        .executableTarget(
            name: "DraftFrame",
            dependencies: ["DraftFrameKit", "SwiftTerm"],
            path: "Sources/DraftFrame",
            exclude: ["AppIcon.png"]
        ),
        .testTarget(
            name: "DraftFrameTests",
            dependencies: ["DraftFrameKit"],
            path: "Tests/DraftFrameTests"
        ),
    ]
)
