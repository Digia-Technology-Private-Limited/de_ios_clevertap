# digia_engage_clevertap_ios

Swift package bridging CleverTap campaigns into the Digia Engage rendering
engine for iOS.

## Usage

```swift
// application(_:didFinishLaunchingWithOptions:), BEFORE CleverTap initialises:
DigiaCleverTapPlugin.prepareCleverTapCustomTemplates()

// After Digia.initialize():
Digia.register(DigiaCleverTapPlugin())
```

`prepareCleverTapCustomTemplates()` is **not optional** for custom-template
campaigns. CleverTap resolves custom templates when its instance is created and
filters out campaigns whose template is not registered, so calling it late
silently loses every custom-template campaign already in flight.

## The two channels

| | Custom template (`DigiaTemplate`) | Native Display (Display Units) |
|---|---|---|
| Holds CleverTap's visual in-app slot | **yes** | no |
| Ordering | queued behind other in-apps | delivered immediately, unordered |
| Impression / click reporting | `presented()` / template `action` | `recordDisplayUnitViewedEvent` / `…ClickedEvent` |
| Cost of a missed terminal call | the app's whole in-app channel stalls | nothing |

## Dashboard template definition

Upload this to CleverTap. It matches what the plugin registers, and is identical
across the iOS, Android and React Native plugins.

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

DEBUG configurations push this automatically on registration. Release builds can
call `DigiaCleverTapPlugin.syncCleverTapCustomTemplates(isProduction: true)`.

### Campaign key aliases

The Native Display path accepts any of these keys in a unit's custom key-values:

`digiaKey`, `digia_key`, `digia-key`, `campaignKey`, `campaign_key`,
`campaign-key`, `digiaCampaign`, `digia_campaign`, `digia-campaign`,
`digiaCampaignKey`, `digia_campaign_key`, `digia-campaign-key`

The custom-template path needs no aliases — its argument name is fixed by the
template definition above.

## Source map

| File | Responsibility |
|---|---|
| `DigiaCleverTapPlugin.swift` | The `DigiaCEPPlugin`: wiring and event routing |
| `TemplateSlot.swift` | Single writer of presentation state; guarantees the in-app slot is freed |
| `CampaignPresentation.swift` | The presentation handle and its exactly-once typed outcome |
| `CleverTapTemplates.swift` | Process-global template/function registration |
| `CleverTapPayloadMapper.swift` | CleverTap data → `CEPTriggerPayload` |
| `CleverTapClient.swift` | The CleverTap SDK seam |

## How the in-app slot is protected

CleverTap shows one visual in-app at a time. A `DigiaTemplate` invocation holds
that slot from the moment its presenter runs until `dismissed()`. A presenter
that takes the slot and never dismisses stalls **every** later in-app — Digia's
and the app's own — for the rest of the session.

`TemplateSlot` is the only writer of that state. Every terminal path — Digia
declining, Digia dismissing, CleverTap closing, teardown, the watchdog — reaches
the slot through one private `settle`, and `settle` is the only caller of
`release`. A 15-second acceptance watchdog backs it up.

Impressions are reported only once Digia actually renders, so a declined
campaign never books a view or consumes frequency budget.

## Testing

```bash
xcodebuild test -scheme DigiaEngageCleverTap \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'
```

`swift test` does not work here: the package is iOS-only and depends on an iOS
xcframework.

## Requirements

- iOS 17+, Swift 6.0+, Xcode 16+
- CleverTap iOS SDK 7.5.1+ (`addActionArgument`, non-visual app functions)

## Engineering notes

Design rationale, the deviations from the Core ↔ CEP Interface v2 spec, and the
corner cases that could **not** be moved into this plugin are recorded in the
workspace: `ai_docs/cep-clevertap-plugin-v2.md`.
