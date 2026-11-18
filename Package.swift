// swift-tools-version: 6.0
// Agneta's logic lives in AgnetaKit so it can be tested without a window;
// the app target is a thin SwiftUI/AppKit layer on top.
import PackageDescription

let package = Package(
    name: "Agneta",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgnetaKit", targets: ["AgnetaKit"]),
        .executable(name: "agneta-probe", targets: ["agneta-probe"]),
        .executable(name: "agneta-shell", targets: ["agneta-shell"]),
        .executable(name: "agnetad", targets: ["agnetad"]),
        .executable(name: "agneta-testclient", targets: ["agneta-testclient"]),
        .executable(name: "agneta-signin", targets: ["agneta-signin"]),
        .executable(name: "Agneta", targets: ["Agneta"]),
        .executable(name: "agneta-diag", targets: ["agneta-diag"]),
        .executable(name: "agneta-fakes", targets: ["agneta-fakes"]),
    ],
    dependencies: [
        // SQLite with migrations. Pinned exactly; updates are deliberate.
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.9.0"),
        // Updates for release builds (docs/RELEASING.md, part 3). Pinned exactly, like GRDB.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .target(name: "AgnetaKit", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "agneta-probe", dependencies: ["AgnetaKit"]),
        // GOOSE_SHELL inside engines: forwards commands to Agneta's tool broker. No dependencies.
        .executableTarget(name: "agneta-shell"),
        // agnetad: a headless development host, never shipped. agneta-testclient: a stand-in app, shipped only
        // inside the development bundle as the panel's sandboxed "Run a Test Task" app.
        .executableTarget(name: "agnetad", dependencies: ["AgnetaKit"]),
        .executableTarget(name: "agneta-testclient"),
        .executableTarget(name: "agneta-signin", dependencies: ["AgnetaKit"]),
        // The app: menu bar panel and windows over AgnetaKit (scripts/dev/build-app bundles it).
        .executableTarget(name: "Agneta", dependencies: ["AgnetaKit", .product(name: "Sparkle", package: "Sparkle")]),
        // Reads task traces for people and scripts (docs/DIAGNOSTICS.md); bundled in the app.
        .executableTarget(name: "agneta-diag", dependencies: ["AgnetaKit"]),
        // The fake model and tool server that tests run engines against; agneta-fakes runs them for tests outside
        // Swift. Development only, never in the app.
        .target(name: "AgnetaFakes"),
        .executableTarget(name: "agneta-fakes", dependencies: ["AgnetaFakes"]),
        .testTarget(name: "AgnetaKitTests", dependencies: ["AgnetaKit", "AgnetaFakes"]),
        // The app's own logic (approvals, sign-in, the engine library), without its windows.
        .testTarget(name: "AgnetaTests", dependencies: ["Agneta"]),
    ]
)
