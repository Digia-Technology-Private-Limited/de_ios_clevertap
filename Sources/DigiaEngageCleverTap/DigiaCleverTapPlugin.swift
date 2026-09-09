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
    private var isSetup = false

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
        guard !isSetup else { return }
        isSetup = true
        self.delegate = delegate
        bridge.registerTemplateCallbacks(
            onPayload: { [weak self] payload in Task { @MainActor in self?.dispatchMappedPayloads(payload) } },
            onInvalidate: { [weak self] campaignId in Task { @MainActor in self?.dispatchInvalidation(campaignId) } }
        )
        bridge.registerInAppListener(
            onPayload: { [weak self] payload in Task { @MainActor in self?.dispatchMappedPayloads(payload) } },
            onInvalidate: { [weak self] campaignId in Task { @MainActor in self?.dispatchInvalidation(campaignId) } }
        )
        // Replay display units fetched before setup() (covers app-launch race).
        bridge.getDisplayUnits().forEach { dispatchMappedPayloads($0) }
    }

    public func forwardScreen(_ name: String) {
        bridge.recordScreen(name)
    }

    public func notifyEvent(_ event: DigiaExperienceEvent, payload: CEPTriggerPayload) {
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
        isSetup = false
    }

    private func dispatchMappedPayloads(_ rawPayload: [String: Any]) {
        guard let delegate else { return }
        for payload in mapper.map(rawPayload) {
            if !delegate.onCampaignTriggered(payload) {
                events.notifyEvent(.dismissed, payload: payload)
            }
        }
    }

    private func dispatchInvalidation(_ campaignId: String) {
        delegate?.onCampaignInvalidated(campaignId)
    }
}
