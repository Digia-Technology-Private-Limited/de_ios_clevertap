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

    @Test("invalid template payloads are dropped")
    func invalidTemplatePayloadsAreDropped() async {
        let bridge = FakeBridge()
        let delegate = RecordingDelegate()
        let plugin = DigiaCleverTapPlugin(bridge: bridge)
        plugin.setup(delegate: delegate)

        bridge.emitTemplatePayload([
            "id": "campaign-1",
            "templateName": "DigiaTemplate",
            "command": "SHOW_DIALOG",
        ])

        await Task.yield()

        #expect(delegate.triggeredPayloads.isEmpty)
    }

    @Test("nudge payload accepts args as JSON string")
    func nudgePayloadAcceptsArgsAsJsonString() async {
        let bridge = FakeBridge()
        let delegate = RecordingDelegate()
        let plugin = DigiaCleverTapPlugin(bridge: bridge)
        plugin.setup(delegate: delegate)

        bridge.emitTemplatePayload([
            "id": "campaign-json-args",
            "templateName": "DigiaTemplate",
            "viewId": "abc-123",
            "command": "SHOW_DIALOG",
            "args": "{\"coupon\": \"SAVE20\"}",
        ])

        await Task.yield()

        #expect(delegate.triggeredPayloads.count == 1)
        let content = delegate.triggeredPayloads.first?.content
        #expect(content?.command == "SHOW_DIALOG")
        #expect(content?.viewId == "abc-123")
        #expect(content?.args == ["coupon": .string("SAVE20")])
    }

    @Test("custom template payloads map args without screen filtering")
    func customTemplatePayloadsMapArgs() async {
        let bridge = FakeBridge()
        let delegate = RecordingDelegate()
        let plugin = DigiaCleverTapPlugin(bridge: bridge)
        plugin.setup(delegate: delegate)

        bridge.emitTemplatePayload([
            "id": "DigiaTemplate:hero",
            "templateName": "DigiaTemplate",
            "viewId": "hero",
            "command": "SHOW_BOTTOM_SHEET",
            "args": ["name": "Ada", "step": 2],
        ])

        await Task.yield()

        #expect(delegate.triggeredPayloads.count == 1)
        #expect(delegate.triggeredPayloads.first?.content.command == "SHOW_BOTTOM_SHEET")
        #expect(delegate.triggeredPayloads.first?.content.viewId == "hero")
        #expect(delegate.triggeredPayloads.first?.content.args == [
            "name": .string("Ada"),
            "step": .int(2),
        ])
    }

    @Test("inline widget payload accepts args as JSON string")
    func inlinePayloadAcceptsArgsAsJsonString() async throws {
        let bridge = FakeBridge()
        let delegate = RecordingDelegate()
        let plugin = DigiaCleverTapPlugin(bridge: bridge)
        plugin.setup(delegate: delegate)

        bridge.emitInAppPayload([
            "id": "campaign-inline-json",
            "placementKey": "home_slot",
            "viewId": "abc-123",
            "args": "{\"coupon\": \"SAVE20\"}",
        ])

        await Task.yield()

        let payload = try #require(delegate.triggeredPayloads.first)
        #expect(payload.content.type == "inline")
        #expect(payload.content.placementKey == "home_slot")
        #expect(payload.content.viewId == "abc-123")
        #expect(payload.content.args == ["coupon": .string("SAVE20")])
    }

    @Test("display unit payloads map to inline payloads")
    func displayUnitPayloadsMapToInlinePayloads() async throws {
        let bridge = FakeBridge()
        let delegate = RecordingDelegate()
        let plugin = DigiaCleverTapPlugin(bridge: bridge)
        plugin.setup(delegate: delegate)

        bridge.emitInAppPayload([
            "id": "campaign-inline",
            "placementKey": "hero_banner",
            "viewId": "hero_component",
            "args": ["name": "Ada"],
        ])

        await Task.yield()

        let payload = try #require(delegate.triggeredPayloads.first)
        #expect(payload.id == "campaign-inline:hero_banner")
        #expect(payload.content.type == "inline")
        #expect(payload.content.placementKey == "hero_banner")
        #expect(payload.content.viewId == "hero_component")
        #expect(payload.content.args == ["name": .string("Ada")])
    }

    @Test("display unit with anchorKey maps to anchored overlay payload")
    func displayUnitWithAnchorKeyMapsToAnchoredOverlay() async throws {
        let bridge = FakeBridge()
        let delegate = RecordingDelegate()
        let plugin = DigiaCleverTapPlugin(bridge: bridge)
        plugin.setup(delegate: delegate)

        bridge.emitInAppPayload([
            "id": "campaign-tooltip",
            "command": "SHOW_TOOLTIP",
            "viewId": "tooltip_component",
            "anchorKey": "checkout_button",
        ])

        await Task.yield()

        let payload = try #require(delegate.triggeredPayloads.first)
        #expect(payload.id == "campaign-tooltip:SHOW_TOOLTIP:checkout_button")
        #expect(payload.content.command == "SHOW_TOOLTIP")
        #expect(payload.content.viewId == "tooltip_component")
        #expect(payload.content.anchorKey == "checkout_button")
    }

    @Test("setup replays display units cached before the delegate was attached")
    func setupReplaysCachedDisplayUnits() async throws {
        // Launch race: CleverTap loaded + fired its display-unit delegate for a
        // unit before setup() attached ours, so the live event was missed. Only
        // the native cache replay can recover it.
        let bridge = FakeBridge()
        bridge.cachedDisplayUnits = [[
            "id": "ct_launch",
            "placementKey": "hero_banner",
            "viewId": "hero_component",
        ]]
        let delegate = RecordingDelegate()
        let plugin = DigiaCleverTapPlugin(bridge: bridge)

        plugin.setup(delegate: delegate)
        await Task.yield()

        #expect(bridge.didReplayCachedDisplayUnits)
        let payload = try #require(delegate.triggeredPayloads.first)
        #expect(payload.id == "ct_launch:hero_banner")
    }

    @Test("replay dedupes cached display units by id")
    func replayDedupesCachedDisplayUnitsByID() async {
        let bridge = FakeBridge()
        let unit: [String: Any] = [
            "id": "ct_dup",
            "placementKey": "hero_banner",
            "viewId": "hero_component",
        ]
        bridge.cachedDisplayUnits = [unit, unit]
        let delegate = RecordingDelegate()
        let plugin = DigiaCleverTapPlugin(bridge: bridge)

        plugin.setup(delegate: delegate)
        await Task.yield()

        #expect(delegate.triggeredPayloads.count == 1)
    }

    @Test("dismissed events dismiss the template and other lifecycle events are no-op")
    func dismissedEventsDismissTemplate() {
        let bridge = FakeBridge()
        let plugin = DigiaCleverTapPlugin(bridge: bridge)
        let payload = InAppPayload(
            id: "DigiaTemplate:hero",
            content: InAppPayloadContent(type: "dialog"),
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
    var didReplayCachedDisplayUnits = false
    var recordedScreens: [String] = []
    var dismissedTemplates: [String] = []
    var available = true
    var defaultInstanceAvailable = true

    /// Units CleverTap has cached natively; replayed (deduped by id) when
    /// `replayCachedDisplayUnits()` is called on register.
    var cachedDisplayUnits: [[String: Any]] = []
    private var replayedUnitIDs = Set<String>()

    private var onTemplatePayload: (([String: Any]) -> Void)?
    private var onTemplateInvalidate: ((String) -> Void)?
    private var onInAppPayload: (([String: Any]) -> Void)?
    private var onInAppInvalidate: ((String) -> Void)?

    func registerTemplateCallbacks(
        onPayload: @escaping ([String: Any]) -> Void,
        onInvalidate: @escaping (String) -> Void
    ) {
        didRegisterTemplateCallbacks = true
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
        onInAppPayload = onPayload
        onInAppInvalidate = onInvalidate
    }

    func unregisterInAppListener() {
        didUnregisterInAppListener = true
        onInAppPayload = nil
        onInAppInvalidate = nil
        replayedUnitIDs.removeAll()
    }

    func replayCachedDisplayUnits() {
        didReplayCachedDisplayUnits = true
        for unit in cachedDisplayUnits {
            if let id = unit["id"] as? String, !replayedUnitIDs.insert(id).inserted {
                continue
            }
            onInAppPayload?(unit)
        }
    }

    func recordScreen(_ name: String) {
        recordedScreens.append(name)
    }

    func dismissTemplate(_ templateName: String) {
        dismissedTemplates.append(templateName)
    }

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
