# Changelog

All notable changes to Digia Engage CleverTap (iOS) are documented in this file.

## [2.0.0] - 2026-10-10

### New Features

- `DigiaTemplate` clicks now run the campaign's primary action (the template's `action` argument) so CleverTap records them; a new non-visual `DigiaPrimaryClick` function records a click only.
- Native Display campaigns now report a view to CleverTap when they render and a click when they are clicked.

### Improvements

- `DigiaTemplate` arguments `viewId`, `command` and `args` are now `digia_campaign_key`, `variables` and `action`; re-upload the template and re-point campaigns, and a template without `digia_campaign_key` is dropped and its in-app slot released.
- Debug builds now push the template definition to the CleverTap dashboard when the plugin registers; release builds can call `DigiaCleverTapPlugin.syncCleverTapCustomTemplates(isProduction: true)`.
- Campaigns now match by campaign key in Native Display key-values under any of twelve spellings (`digiaKey`, `digia_key`, `campaignKey`, `campaign_key` and their dashed and `digiaCampaign…` forms); the old `command` / `viewId` / `placementKey` format is no longer read.
- Campaign variables are read from the template's `variables` argument or a Native Display `variables` blob (`args` still accepted), delivered as strings, with unquoted values recovered and booleans as `true` / `false`.
- `DigiaCleverTapPlugin` now implements the Digia Engage `DigiaCEPPlugin` host contract and requires Digia Engage 4.0.0 or later.
- The CleverTap iOS SDK dependency is now `>= 7.5.1, < 8.0` instead of exactly 7.5.1.
- The minimum iOS version is now 15 instead of 16.

### Bug Fixes

- CleverTap's in-app queue no longer stalls when Digia declines a campaign; the slot is now released on every outcome.
- CleverTap view counts and frequency budget now record only once Digia actually renders the campaign.
- Templates and Native Display units delivered while Digia is still initialising are now held and shown once it is ready instead of being dropped, and units CleverTap cached before the plugin attached are recovered.
- A standard CleverTap in-app carrying Digia key-values no longer triggers a Digia campaign, and the plugin no longer replaces the app's own in-app notification delegate.
