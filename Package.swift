// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DigiaEngageCleverTap",
    platforms: [
        // NOTE (local dev, uncommitted): bumped from .v16 — core now requires iOS 17.
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "DigiaEngageCleverTap",
            targets: ["DigiaEngageCleverTap"]
        ),
    ],
    dependencies: [
        // NOTE (local dev, uncommitted): pointed at the sibling checkout instead of
        // `from: "1.0.0"` — that constraint predates core's 3.2.0 release and forces
        // SPM to resolve the old pre-CEPTriggerPayload core. This package's own
        // source already targets current core; only this manifest line was stale.
        .package(path: "../core"),
        .package(url: "https://github.com/CleverTap/clevertap-ios-sdk.git", exact: "7.5.1"),
    ],
    targets: [
        .target(
            name: "DigiaEngageCleverTap",
            dependencies: [
                .product(name: "DigiaEngage", package: "core"),
                .product(name: "CleverTapSDK", package: "clevertap-ios-sdk"),
            ],
            path: "Sources/DigiaEngageCleverTap"
        ),
        .testTarget(
            name: "DigiaEngageCleverTapTests",
            dependencies: ["DigiaEngageCleverTap"],
            path: "Tests/DigiaEngageCleverTapTests"
        ),
    ]
)
