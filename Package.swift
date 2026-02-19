// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeHub",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", branch: "main")
    ],
    targets: [
        .executableTarget(
            name: "ClaudeHub",
            dependencies: ["SwiftTerm"],
            path: "ClaudeHub",
            resources: [.copy("Resources/AppIcon.icns")]
        )
    ]
)
