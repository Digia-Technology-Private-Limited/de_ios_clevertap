# DigiaEngageCleverTap iOS

[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FDigia-Technology-Private-Limited%2Fdigia_expr_swift%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/Digia-Technology-Private-Limited/digia_engage_clevertap_ios)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FDigia-Technology-Private-Limited%2Fdigia_expr_swift%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/Digia-Technology-Private-Limited/digia_engage_clevertap_ios)
[![License: BSL 1.1](https://img.shields.io/badge/License-BSL%201.1-blue.svg)](LICENSE)

A [Digia Engage](https://github.com/Digia-Technology-Private-Limited/digia_engage_ios) plugin that bridges CleverTap custom templates and display units into the Digia rendering engine. Enables CleverTap campaigns to render Digia-powered UI experiences.

## Requirements

| | Minimum |
|---|---|
| iOS | 15.0 |
| Swift | 6.0 |
| Xcode | 16.0 |
| CleverTap iOS SDK | 7.5.1 |

## Installation

### Swift Package Manager

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(
        url: "https://github.com/Digia-Technology-Private-Limited/digia_engage_clevertap_ios.git",
        from: "1.0.0"
    ),
]
```

Then add `DigiaEngageCleverTap` as a target dependency:

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "DigiaEngageCleverTap", package: "digia_engage_clevertap_ios"),
    ]
)
```

Or add it directly in Xcode via **File → Add Package Dependencies** and enter the repository URL.

## Usage

### 1. Initialize Digia Engage

```swift
import DigiaEngage

try await Digia.initialize(
    config: DigiaConfig(apiKey: "YOUR_DIGIA_API_KEY")
)
```

### 2. Register the CleverTap custom templates

Do this **before** CleverTap initialises, in
`application(_:didFinishLaunchingWithOptions:)`:

```swift
import DigiaEngageCleverTap

DigiaCleverTapPlugin.prepareCleverTapCustomTemplates()
```

This is not optional for custom-template campaigns. CleverTap resolves custom
templates when its instance is created and filters out campaigns whose template
is not registered.

### 3. Register the plugin

```swift
Digia.register(DigiaCleverTapPlugin())
```

### 4. Add the template to your CleverTap dashboard

```json
{
  "DigiaTemplate": {
    "type": "template",
    "arguments": {
      "digia_campaign_key": { "type": "string", "value": "" },
      "variables":          { "type": "string", "value": "{}" },
      "action":             { "type": "action" }
    }
  },
  "DigiaPrimaryClick": {
    "type": "function",
    "isVisual": false,
    "arguments": {}
  }
}
```

DEBUG builds push this definition automatically when the plugin registers.

## License

[BSL 1.1](LICENSE) — Business Source License 1.1. Source available; production use requires a license from Digia Technology.

---

Built with ❤️ by the [Digia](https://digia.tech) team
