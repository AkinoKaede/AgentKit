// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "AgentKit", targets: ["AgentKit"])
    ],
    targets: [
        .target(
            name: "AgentKit",
            resources: [.process("Resources")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                // Nothing in this package touches a UI framework, so the useful
                // default is the opposite of an app's: types are nonisolated
                // unless they say otherwise, and the few that are actors say so.
                .defaultIsolation(nil),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "AgentKitTests",
            dependencies: ["AgentKit"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(nil),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
    ]
)
