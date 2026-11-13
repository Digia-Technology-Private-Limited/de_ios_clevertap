// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DigiaEngageCleverTap",
    platforms: [
        // Follows core, which requires iOS 15. Keep these in lockstep with
        // DigiaEngage's Package.swift and podspec — a plugin must never demand a
        // higher floor than the core it depends on, or it silently excludes apps
        // that can run the core perfectly well.
        .iOS(.v15),
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
        // A range, never an exact pin. 7.8.1 is the floor (`addActionArgument`,
        // non-visual app functions); an exact pin here propagates into every host
        // app that resolves this package and deadlocks against any other pin on
        // the same SDK — the `clevertap_plugin 3.8.1` failure mode, and more
        // likely here because a host app almost certainly already carries
        // CleverTap. Forward note: the PIP/Native-Display work raised the floor
        // past 7.7.1 (ai_docs/cep-v2-native-rn-plan.md, "Version notes").
        .package(url: "https://github.com/CleverTap/clevertap-ios-sdk.git", from: "7.8.1"),
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
