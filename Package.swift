// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DigiaEngageCleverTap",
    platforms: [
        // Follows core, which requires iOS 17.
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "DigiaEngageCleverTap",
            targets: ["DigiaEngageCleverTap"]
        ),
    ],
    dependencies: [
        // The sibling checkout, not `from: "1.0.0"` — that constraint predates
        // core's CEPTriggerPayload release and resolves a core this package can no
        // longer compile against. Repoint at a version tag once core publishes one
        // carrying the current CEP contract.
        .package(path: "../core"),
        // 7.5.1+ is required for `addActionArgument` and non-visual app functions.
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
