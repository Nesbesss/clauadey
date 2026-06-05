// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Claudey",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Claudey",
            path: "Sources/Claudey"
        )
    ]
)
