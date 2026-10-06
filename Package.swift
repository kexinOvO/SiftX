// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SiftX",
    platforms: [.macOS(.v14)],
    products: [.library(name: "SiftXCore", targets: ["SiftXCore"])],
    targets: [
        .target(name: "SiftXCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "SiftXCoreTests", dependencies: ["SiftXCore"]),
        .target(name: "SafariExtensionState", path: "SafariExtension/State"),
        .testTarget(name: "SafariExtensionStateTests", dependencies: ["SafariExtensionState"]),
        .target(name: "MediaPreviewNetworking", dependencies: ["SiftXCore"], path: "SafariExtension/PreviewNetworking"),
        .testTarget(name: "MediaPreviewTests", dependencies: ["MediaPreviewNetworking", "SiftXCore"])
    ]
)
