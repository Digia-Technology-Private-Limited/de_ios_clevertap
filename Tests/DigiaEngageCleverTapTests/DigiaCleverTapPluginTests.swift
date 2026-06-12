@testable import DigiaEngage
@testable import DigiaEngageCleverTap
import Foundation
import Testing

@MainActor
@Suite("DigiaCleverTapPlugin", .serialized)
struct DigiaCleverTapPluginTests {
    @Test("setup registers callbacks and attaches delegate")
    func setupRegistersCallbacks() {
        let bridge = FakeBridge()
        let delegate = RecordingDelegate()
        let plugin = DigiaCleverTapPlugin(bridge: bridge)

        plugin.setup(delegate: delegate)

        #expect(bridge.didRegisterTemplateCallbacks)
        #expect(bridge.didRegisterInAppListener)
    }

    @Test("forwardScreen records the screen through the bridge")
    func forwardScreenRecordsThroughBridge() {
        let bridge = FakeBridge()
        let plugin = DigiaCleverTapPlugin(bridge: bridge)

        plugin.forwardScreen("checkout")

        #expect(bridge.recordedScreens == ["checkout"])
    }

    @Test("payload without campaign key is dropped")
    func payloadWithoutCampaignKeyIsDropped() async {
        let bridge = FakeBridge()
        let delegate = RecordingDelegate()
        let plugin = DigiaCleverTapPlugin(bridge: bridge)
        plugin.setup(delegate: delegate)

        bridge.emitTemplatePayload([
            "id": "campaign-1",
            "templateName": "DigiaTemplate",
        ])

        await Task.yield()

        #expect(delegate.triggeredPayloads.isEmpty)
    }

    @Test("campaign key payload maps to overlay")
    func campaignKeyPayloadMapsToOverlay() async {
        let bridge = FakeBridge()
        let delegate = RecordingDelegate()
        let plugin = DigiaCleverTapPlugin(bridge: bridge)
        plugin.setup(delegate: delegate)

        bridge.emitTemplatePayload([
            "id": "campaign-1",
            "templateName": "DigiaTemplate",
            "digia_campaign_key": "welcome_nudge",
        ])

        await Task.yield()

        #expect(delegate.triggeredPayloads.count == 1)
        let content = delegate.triggeredPayloads.first?.content
        #expect(content?.type == "overlay")
        #expect(content?.campaignKey == "welcome_nudge")
    }

    @Test("campaign key payload accepts all aliases")
    func campaignKeyPayloadAcceptsAllAliases() async {
        let aliases = [
            "digiaKey", "digia_key", "digia-key",
            "campaignKey", "campaign_key", "campaign-key",
            "digiaCampaign", "digia_campaign", "digia-campaign",
            "digiaCampaignKey", "digia_campaign_key", "digia-campaign-key",
        ]

        for alias in aliases {
            let bridge = FakeBridge()
            let delegate = RecordingDelegate()
            let plugin = DigiaCleverTapPlugin(bridge: bridge)
            plugin.setup(delegate: delegate)

            bridge.emitInAppPayload([
                "id": "campaign-alias",
                alias: "my_nudge",
            ])

            await Task.yield()

            #expect(delegate.triggeredPayloads.count == 1, "alias '\(alias)' should produce one payload")
            #expect(delegate.triggeredPayloads.first?.content.campaignKey == "my_nudge")
        }
    }

    @Test("campaign key payload parses variables from $variables blob")
    func campaignKeyPayloadParsesVariables() async {
        let bridge = FakeBridge()
        let delegate = RecordingDelegate()
        let plugin = DigiaCleverTapPlugin(bridge: bridge)
        plugin.setup(delegate: delegate)

        bridge.emitTemplatePayload([
            "id": "campaign-vars",
            "templateName": "DigiaTemplate",
            "digia_campaign_key": "promo_nudge",
            "$variables": "{\"name\": \"Alice\", \"discount\": \"20\"}",
        ])

        await Task.yield()

        #expect(delegate.triggeredPayloads.count == 1)
        let variables = delegate.triggeredPayloads.first?.content.variables
        #expect(variables?["name"] == "Alice")
        #expect(variables?["discount"] == "20")
    }

    @Test("display unit with campaign key maps to overlay payload")
    func displayUnitWithCampaignKeyMapsToOverlay() async throws {
        let bridge = FakeBridge()
        let delegate = RecordingDelegate()
        let plugin = DigiaCleverTapPlugin(bridge: bridge)
        plugin.setup(delegate: delegate)

        bridge.emitInAppPayload([
            "id": "campaign-unit",
            "digia_campaign_key": "feature_nudge",
        ])

        await Task.yield()

        let payload = try #require(delegate.triggeredPayloads.first)
        #expect(payload.id == "campaign-unit")
        #expect(payload.content.type == "overlay")
        #expect(payload.content.campaignKey == "feature_nudge")
    }

    @Test("dismissed events dismiss the template and other lifecycle events are no-op")
    func dismissedEventsDismissTemplate() {
        let bridge = FakeBridge()
        let plugin = DigiaCleverTapPlugin(bridge: bridge)
        let payload = InAppPayload(
            id: "welcome_nudge",
            content: InAppPayloadContent(type: "overlay", campaignKey: "welcome_nudge"),
            cepContext: ["templateName": "DigiaTemplate"]
        )

        plugin.notifyEvent(.impressed, payload: payload)
        plugin.notifyEvent(.clicked(elementID: "cta"), payload: payload)
        plugin.notifyEvent(.dismissed, payload: payload)

        #expect(bridge.dismissedTemplates == ["DigiaTemplate"])
    }

    @Test("teardown unregisters listeners and clears state")
    func teardownUnregistersListeners() {
        let bridge = FakeBridge()
        let delegate = RecordingDelegate()
        let plugin = DigiaCleverTapPlugin(bridge: bridge)
        plugin.setup(delegate: delegate)

        plugin.teardown()

        #expect(bridge.didUnregisterInAppListener)
        #expect(bridge.didUnregisterTemplateCallbacks)
        #expect(plugin.healthCheck().metadata["delegateAttached"] == "false")
    }

    @Test("setup is idempotent")
    func setupIsIdempotent() {
        let bridge = FakeBridge()
        let delegate = RecordingDelegate()
        let plugin = DigiaCleverTapPlugin(bridge: bridge)

        plugin.setup(delegate: delegate)
        plugin.setup(delegate: delegate) // second call must be no-op

        #expect(bridge.templateCallbackRegistrationCount == 1)
        #expect(bridge.inAppListenerRegistrationCount == 1)
    }

    @Test("teardown resets setup flag so re-setup works")
    func teardownAllowsReSetup() {
        let bridge = FakeBridge()
        let plugin = DigiaCleverTapPlugin(bridge: bridge)
        plugin.setup(delegate: RecordingDelegate())
        plugin.teardown()

        let delegate2 = RecordingDelegate()
        plugin.setup(delegate: delegate2)
        bridge.emitInAppPayload(["id": "after-reset", "digia_campaign_key": "nudge"])

        #expect(!delegate2.triggeredPayloads.isEmpty)
    }

    @Test("cached display units are replayed on setup")
    func cachedDisplayUnitsReplayedOnSetup() async {
        let bridge = FakeBridge()
        bridge.stubbedDisplayUnits = [
            ["id": "unit-1", "digia_campaign_key": "cached_nudge"],
        ]
        let delegate = RecordingDelegate()
        let plugin = DigiaCleverTapPlugin(bridge: bridge)
        plugin.setup(delegate: delegate)

        await Task.yield()

        #expect(delegate.triggeredPayloads.count == 1)
        #expect(delegate.triggeredPayloads.first?.content.campaignKey == "cached_nudge")
    }

    @Test("healthCheck reports unhealthy when default instance is unavailable")
    func healthCheckReportsUnhealthyWhenBridgeIsNotReady() {
        let bridge = FakeBridge()
        bridge.defaultInstanceAvailable = false
        let delegate = RecordingDelegate()
        let plugin = DigiaCleverTapPlugin(bridge: bridge)
        plugin.setup(delegate: delegate)

        let report = plugin.healthCheck()

        #expect(!report.isHealthy)
        #expect(report.metadata["defaultInstanceAvailable"] == "false")
    }
}

private final class FakeBridge: CleverTapBridge {
    var didRegisterTemplateCallbacks = false
    var didUnregisterTemplateCallbacks = false
    var didRegisterInAppListener = false
    var didUnregisterInAppListener = false
    var templateCallbackRegistrationCount = 0
    var inAppListenerRegistrationCount = 0
    var recordedScreens: [String] = []
    var dismissedTemplates: [String] = []
    var available = true
    var defaultInstanceAvailable = true
    var stubbedDisplayUnits: [[String: Any]] = []

    private var onTemplatePayload: (([String: Any]) -> Void)?
    private var onTemplateInvalidate: ((String) -> Void)?
    private var onInAppPayload: (([String: Any]) -> Void)?
    private var onInAppInvalidate: ((String) -> Void)?

    func registerTemplateCallbacks(
        onPayload: @escaping ([String: Any]) -> Void,
        onInvalidate: @escaping (String) -> Void
    ) {
        didRegisterTemplateCallbacks = true
        templateCallbackRegistrationCount += 1
        onTemplatePayload = onPayload
        onTemplateInvalidate = onInvalidate
    }

    func unregisterTemplateCallbacks() {
        didUnregisterTemplateCallbacks = true
        onTemplatePayload = nil
        onTemplateInvalidate = nil
    }

    func registerInAppListener(
        onPayload: @escaping ([String: Any]) -> Void,
        onInvalidate: @escaping (String) -> Void
    ) {
        didRegisterInAppListener = true
        inAppListenerRegistrationCount += 1
        onInAppPayload = onPayload
        onInAppInvalidate = onInvalidate
    }

    func unregisterInAppListener() {
        didUnregisterInAppListener = true
        onInAppPayload = nil
        onInAppInvalidate = nil
    }

    func recordScreen(_ name: String) {
        recordedScreens.append(name)
    }

    func dismissTemplate(_ templateName: String) {
        dismissedTemplates.append(templateName)
    }

    func getDisplayUnits() -> [[String: Any]] { stubbedDisplayUnits }

    func isAvailable() -> Bool { available }

    func hasDefaultInstance() -> Bool { defaultInstanceAvailable }

    func emitTemplatePayload(_ payload: [String: Any]) {
        onTemplatePayload?(payload)
    }

    func emitInAppPayload(_ payload: [String: Any]) {
        onInAppPayload?(payload)
    }
}

private final class RecordingDelegate: DigiaCEPDelegate {
    var triggeredPayloads: [InAppPayload] = []
    var invalidatedCampaignIDs: [String] = []

    func onCampaignTriggered(_ payload: InAppPayload) {
        triggeredPayloads.append(payload)
    }

    func onCampaignInvalidated(_ campaignID: String) {
        invalidatedCampaignIDs.append(campaignID)
    }
}
