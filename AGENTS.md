# digia_engage_clevertap_ios

Swift package that bridges CleverTap custom templates and display units into the Digia Engage rendering engine for iOS.

## Purpose

Registers the `DigiaTemplate` CleverTap custom template. When CleverTap fires it, the plugin extracts `digia_campaign_key` and forwards an `InAppPayload` to the Digia SDK.

## Template

The `DigiaTemplate` has exactly two arguments:

| Argument           | Type   | Default |
|--------------------|--------|---------|
| `digia_campaign_key` | string | `""`    |
| `variables`        | string | `"{}"`  |

## Campaign Key Aliases

The flat-map path (in-app notifications, display units) accepts any of:
`digiaKey`, `digia_key`, `digia-key`, `campaignKey`, `campaign_key`, `campaign-key`, `digiaCampaign`, `digia_campaign`, `digia-campaign`, `digiaCampaignKey`, `digia_campaign_key`, `digia-campaign-key`

## Usage

```swift
import DigiaEngageCleverTap

// Register template before CleverTap initializes:
DigiaCleverTapPlugin.prepareCleverTapCustomTemplates()

// Register plugin after Digia initializes:
Digia.register(DigiaCleverTapPlugin())
```

## Requirements

- iOS 16.0+, Swift 6.0+, Xcode 16.0+
- CleverTap iOS SDK 7.5.1+
