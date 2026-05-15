// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "git-notified",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "git-notified", targets: ["GitNotified"]),
    ],
    targets: [
        .executableTarget(
            name: "GitNotified",
            path: "Sources/GitNotified"
        ),
    ]
)
