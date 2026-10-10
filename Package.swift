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
        // 4.0.0 is the first core release carrying the CEP v2 contract this package
        // compiles against; a range, so a host app can take any later 4.x.
        .package(
            url: "https://github.com/Digia-Technology-Private-Limited/digia_engage_ios.git",
            from: "4.0.0"
        ),
        // A range, never an exact pin. 7.5.1 is the floor (`addActionArgument`,
        // non-visual app functions); an exact pin here propagates into every host
        // app that resolves this package and deadlocks against any other pin on
        // the same SDK — the `clevertap_plugin 3.8.1` failure mode, and more
        // likely here because a host app almost certainly already carries
        // CleverTap. Forward note: the PIP/Native-Display work raises the floor
        // to 7.7.1 (ai_docs/cep-v2-native-rn-plan.md, "Version notes").
        .package(url: "https://github.com/CleverTap/clevertap-ios-sdk.git", from: "7.5.1"),
    ],
    targets: [
        .target(
            name: "DigiaEngageCleverTap",
            dependencies: [
                .product(name: "DigiaEngage", package: "digia_engage_ios"),
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
