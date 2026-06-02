import DigiaEngage
import CleverTapSDK
import Foundation

@MainActor
public final class DigiaCleverTapPlugin: DigiaCEPPlugin {
    public let identifier = "clevertap"

    private let bridge: CleverTapBridge
    private let mapper: CleverTapPayloadMapper
    private let events: CleverTapEventBridge
    private weak var delegate: DigiaCEPDelegate?

    public init() {
        let bridge = CleverTapSdkBridge()
        self.bridge = bridge
        self.mapper = CleverTapPayloadMapper()
        self.events = CleverTapEventBridge(bridge: bridge)
        CleverTapTemplateRegistration.register()
    }

    internal init(bridge: CleverTapBridge, mapper: CleverTapPayloadMapper = CleverTapPayloadMapper()) {
        self.bridge = bridge
        self.mapper = mapper
        self.events = CleverTapEventBridge(bridge: bridge)
    }

    public static func prepareCleverTapCustomTemplates() {
        CleverTapTemplateRegistration.register()
    }

    public static func syncCleverTapCustomTemplates(isProduction: Bool = false) {
        guard let instance = CleverTap.sharedInstance() else { return }
        if isProduction {
            instance.syncCustomTemplates(true)
        } else {
            instance.syncCustomTemplates()
        }
    }

    public func setup(delegate: DigiaCEPDelegate) {
        self.delegate = delegate
        bridge.registerTemplateCallbacks(
            onPayload: { [weak self] payload in Task { @MainActor in self?.dispatchMappedPayloads(payload) } },
            onInvalidate: { [weak self] campaignId in Task { @MainActor in self?.dispatchInvalidation(campaignId) } }
        )
        bridge.registerInAppListener(
            onPayload: { [weak self] payload in Task { @MainActor in self?.dispatchMappedPayloads(payload) } },
            onInvalidate: { [weak self] campaignId in Task { @MainActor in self?.dispatchInvalidation(campaignId) } }
        )
        // Recover display units that loaded on app launch before the delegate
        // above was attached (the launch race). Deduped by unit id in the bridge.
        bridge.replayCachedDisplayUnits()
    }

    public func notifyEvent(_ event: DigiaExperienceEvent, payload: InAppPayload) {
        events.notifyEvent(event, payload: payload)
    }

    public func healthCheck() -> DiagnosticReport {
        let delegateAttached = delegate != nil
        let defaultInstance = bridge.hasDefaultInstance()
        let bridgeAvailable = bridge.isAvailable()
        let healthy = delegateAttached && defaultInstance && bridgeAvailable
        return DiagnosticReport(
            isHealthy: healthy,
            issue: healthy ? nil : "clevertap plugin not fully wired",
            resolution: healthy ? nil : "call Digia.register(DigiaCleverTapPlugin()) after CleverTap and Digia setup",
            metadata: [
                "identifier": identifier,
                "delegateAttached": String(delegateAttached),
                "defaultInstanceAvailable": String(defaultInstance),
                "bridgeAvailable": String(bridgeAvailable),
            ]
        )
    }

    public func teardown() {
        bridge.unregisterInAppListener()
        bridge.unregisterTemplateCallbacks()
        delegate = nil
    }

    private func dispatchMappedPayloads(_ rawPayload: [String: Any]) {
        guard let delegate else { return }
        mapper.map(rawPayload).forEach(delegate.onCampaignTriggered)
    }

    private func dispatchInvalidation(_ campaignId: String) {
        delegate?.onCampaignInvalidated(campaignId)
    }
}
