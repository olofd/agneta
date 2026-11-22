// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgnetaClient",
    platforms: [.macOS(.v14)],
    products: [.library(name: "AgnetaClient", targets: ["AgnetaClient"])],
    targets: [
        .target(name: "AgnetaClient"),
        .testTarget(name: "AgnetaClientTests", dependencies: ["AgnetaClient"])
    ]
)
