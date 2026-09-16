@testable import DigiaEngage
@testable import DigiaEngageCleverTap
import Foundation
import Testing

/// Mapping tests.
///
/// The variables parser earns its tests: a live CleverTap campaign can
/// interpolate profile values into the `variables` blob unquoted, producing
/// something that is *nearly* JSON. Getting that wrong renders the campaign with
/// raw `{{placeholder}}` text in front of a real user, so both the strict and the
/// lenient path are pinned.
@MainActor
@Suite("CleverTapPayloadMapper")
struct CleverTapPayloadMapperTests {

    private let mapper = CleverTapPayloadMapper()

    // MARK: - Custom template

    @Test("maps a template invocation to a trigger")
    func mapsTemplate() throws {
        let trigger = try #require(mapper.mapTemplate(FakeTemplateHandle(campaignKey: "  onboarding_tip  ")))

        #expect(trigger.campaignKey == "onboarding_tip")
        #expect(trigger.cepCampaignId == "onboarding_tip")
        #expect(trigger.cepMetadata[CleverTapPayloadMapper.metadataTemplateName] == CleverTapTemplates.templateName)
        #expect(trigger.variables == nil, "no variables declared")
    }

    @Test("rejects a template with no usable campaign key")
    func rejectsMissingCampaignKey() {
        #expect(mapper.mapTemplate(FakeTemplateHandle(campaignKey: nil)) == nil)
        #expect(mapper.mapTemplate(FakeTemplateHandle(campaignKey: "")) == nil)
        #expect(mapper.mapTemplate(FakeTemplateHandle(campaignKey: "   ")) == nil)
    }

    @Test("parses a strict JSON variables blob")
    func parsesStrictJson() throws {
        let trigger = try #require(
            mapper.mapTemplate(FakeTemplateHandle(variables: #"{"name":"Priya","visits":3,"vip":true}"#))
        )

        #expect(trigger.variables?["name"] == "Priya")
        #expect(trigger.variables?["visits"] == "3")
        #expect(trigger.variables?["vip"] == "1", "NSNumber bridges booleans to 1/0")
    }

    @Test("falls back to lenient parsing for unquoted profile values")
    func parsesUnquotedProfileValues() throws {
        // CleverTap profile interpolation can emit this; strict JSON parsing fails.
        let trigger = try #require(
            mapper.mapTemplate(FakeTemplateHandle(variables: #"{"name": Priya, "offer": "20%"}"#))
        )

        #expect(trigger.variables?["name"] == "Priya")
        #expect(trigger.variables?["offer"] == "20%")
    }

    @Test("an empty variables blob yields no variables")
    func emptyBlobYieldsNothing() {
        #expect(mapper.mapTemplate(FakeTemplateHandle(variables: "{}"))?.variables == nil)
        #expect(mapper.mapTemplate(FakeTemplateHandle(variables: "   "))?.variables == nil)
    }

    // MARK: - Native Display

    @Test("maps a display unit and marks it as Native Display")
    func mapsDisplayUnit() throws {
        let triggers = mapper.mapDisplayUnits([displayUnit("unit_1", campaignKey: "promo_banner")])

        let trigger = try #require(triggers.first)
        #expect(triggers.count == 1)
        #expect(trigger.campaignKey == "promo_banner")
        #expect(trigger.cepCampaignId == "unit_1")
        // Presence of this is what routes lifecycle events to the tracking path
        // instead of the in-app slot.
        #expect(trigger.cepMetadata[CleverTapPayloadMapper.metadataDisplayUnitId] == "unit_1")
    }

    @Test("accepts every documented campaign key alias")
    func acceptsAllAliases() {
        for alias in CleverTapPayloadMapper.campaignKeyNames {
            let units = [DisplayUnit(unitId: "unit", customKeyValues: [alias: "keyed_campaign"])]
            #expect(
                mapper.mapDisplayUnits(units).first?.campaignKey == "keyed_campaign",
                "alias '\(alias)' must resolve"
            )
        }
    }

    @Test("skips units that are not Digia campaigns")
    func skipsNonDigiaUnits() {
        let units = [
            DisplayUnit(unitId: "no_key_unit", customKeyValues: ["headline": "Hello"]),
            DisplayUnit(unitId: "", customKeyValues: ["digia_campaign_key": "no_id"]),
        ]

        #expect(mapper.mapDisplayUnits(units).isEmpty)
    }

    @Test("builds variables from flat key-values, excluding reserved keys")
    func buildsVariablesFromKeyValues() {
        let units = [
            displayUnit(
                "unit_1",
                campaignKey: "promo_banner",
                extra: [
                    "headline": "Big sale",
                    "wzrk_pivot": "control",
                    "campaignId": "should-be-ignored",
                ]
            ),
        ]

        #expect(mapper.mapDisplayUnits(units).first?.variables == ["headline": "Big sale"])
    }

    @Test("merges the variables blob with flat key-values")
    func mergesBlobAndKeyValues() {
        let units = [
            displayUnit(
                "unit_1",
                campaignKey: "promo_banner",
                extra: ["$variables": #"{"name":"Priya"}"#, "headline": "Big sale"]
            ),
        ]

        #expect(
            mapper.mapDisplayUnits(units).first?.variables == ["name": "Priya", "headline": "Big sale"]
        )
    }
}
