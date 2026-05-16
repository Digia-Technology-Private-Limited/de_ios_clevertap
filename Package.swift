// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DigiaEngageCleverTap",
    platforms: [
        .iOS(.v16),
    ],
    products: [
        .library(
            name: "DigiaEngageCleverTap",
            targets: ["DigiaEngageCleverTap"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/Digia-Technology-Private-Limited/digia_engage_ios.git", from: "1.0.0"),
        .package(url: "https://github.com/CleverTap/clevertap-ios-sdk.git", exact: "7.5.1"),
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
