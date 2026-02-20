// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Shellspace",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", branch: "main")
    ],
    targets: [
        .executableTarget(
            name: "Shellspace",
            dependencies: ["SwiftTerm"],
            path: "Shellspace",
            resources: [.copy("Resources/AppIcon.icns")]
        )
    ]
)
