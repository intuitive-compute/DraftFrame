// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DraftFrame",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "DraftFrame",
            dependencies: ["SwiftTerm"],
            path: "Sources"
        ),
    ]
)
