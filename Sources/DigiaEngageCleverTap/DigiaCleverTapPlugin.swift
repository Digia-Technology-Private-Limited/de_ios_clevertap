@_exported import DigiaEngage
import CleverTapSDK
import Foundation

/// Bridges CleverTap campaigns into the Digia Engage rendering engine.
///
/// ## Usage
///
/// ```swift
/// // application(_:didFinishLaunchingWithOptions:), BEFORE CleverTap initialises:
/// DigiaCleverTapPlugin.prepareCleverTapCustomTemplates()
///
/// // After Digia.initialize():
/// Digia.register(DigiaCleverTapPlugin())
/// ```
///
/// The first call is not optional for custom-template campaigns. CleverTap
/// requires templates to be registered before the instance is created, and
/// filters out campaigns targeting an unregistered template
/// (`docs-internal/cep-integrations/clevertap.md` §9.1).
///
/// ## The two channels
///
/// CleverTap can reach Digia two ways, and they behave differently enough that
/// the plugin keeps them strictly apart:
///
/// | | Custom template (`DigiaTemplate`) | Native Display (Display Units) |
/// |---|---|---|
/// | Holds CleverTap's visual in-app slot | yes — ``TemplateSlot`` owns it | no |
/// | Ordering | queued behind other in-apps | delivered immediately, unordered |
/// | Impression / click reporting | `presented` / `triggerAction` | `recordDisplayUnitViewedEvent` / `…ClickedEvent` |
/// | Cost of a missed terminal call | the customer's whole in-app channel stalls | nothing |
///
/// Everything that can stall is therefore funnelled through ``TemplateSlot``,
/// which guarantees the slot is freed on every terminal path. The Native Display
/// path needs no such machinery: it is pure reporting.
@MainActor
public final class DigiaCleverTapPlugin: DigiaCEPPlugin, TemplateSink {

    public let identifier = "clevertap"

    private let client: CleverTapClient
    private let mapper: CleverTapPayloadMapper
    private let acceptanceTimeout: TimeInterval
    private let watchdogScheduler: WatchdogScheduling

    private weak var delegate: DigiaCEPDelegate?
    private var slot: TemplateSlot?
    private var isSetup = false

    /// Display Unit batches that arrived before ``setup(delegate:)``.
    ///
    /// CleverTap can deliver `app_opened` units while `Digia.initialize()` is
    /// still in flight, so the listener is installed at construction and buffers
    /// until there is a delegate to hand them to. Unlike a custom template, a
    /// buffered unit holds nothing hostage — it is data, not a slot.
    private var pendingDisplayUnits: [DisplayUnit] = []

    public convenience init() {
        self.init(client: CleverTapSdkClient())
    }

    init(
        client: CleverTapClient,
        mapper: CleverTapPayloadMapper = CleverTapPayloadMapper(),
        acceptanceTimeout: TimeInterval = TemplateSlot.defaultAcceptanceTimeout,
        watchdogScheduler: WatchdogScheduling = TaskWatchdogScheduler()
    ) {
        self.client = client
        self.mapper = mapper
        self.acceptanceTimeout = acceptanceTimeout
        self.watchdogScheduler = watchdogScheduler

        // Safety net only — by the time a plugin instance exists CleverTap has
        // usually initialised, and any campaign that targeted the template before
        // then was already filtered out. prepareCleverTapCustomTemplates() is the
        // supported path.
        CleverTapTemplates.register()
        // Installed now, not in setup(), so an app-launch Native Display batch is
        // not lost while Digia is still initialising.
        installDisplayUnitListener()
    }

    // MARK: - DigiaCEPPlugin

    /// Called by `Digia.register()`. Do not call manually.
    public func setup(delegate: DigiaCEPDelegate) {
        guard !isSetup else { return }
        isSetup = true
        self.delegate = delegate

        slot = TemplateSlot(
            acceptanceTimeout: acceptanceTimeout,
            watchdogScheduler: watchdogScheduler,
            onDeliver: { [weak delegate] trigger in delegate?.onCampaignTriggered(trigger) ?? false },
            onInvalidate: { [weak delegate] campaignID in delegate?.onCampaignInvalidated(campaignID) }
        )

        // Must come after the slot exists: attaching flushes any template
        // invocation buffered before registration, synchronously.
        CleverTapTemplates.attach(self)

        if !client.hasInstance() {
            Log.warn(
                "no CleverTap instance available — Native Display and screen forwarding are "
                    + "inactive. Initialise CleverTap before Digia.register()."
            )
        } else {
            // Re-installed unconditionally: constructing a replacement plugin
            // installs its listener before the outgoing plugin's teardown clears
            // it, so setup() is the only point guaranteed to run last.
            installDisplayUnitListener()
            #if DEBUG
            client.syncRegisteredTemplates(isProduction: false)
            #endif
        }

        if !pendingDisplayUnits.isEmpty {
            let buffered = pendingDisplayUnits
            pendingDisplayUnits = []
            Log.info("flushing \(buffered.count) Display Unit(s) buffered before setup")
            deliverDisplayUnits(buffered)
        }

        // Recovers units whose live callback fired before this plugin existed —
        // the native-before-wrapper race. Not campaign history: CleverTap's cache
        // holds only what is currently active (`clevertap.md` §12.6).
        let cached = client.cachedDisplayUnits()
        if !cached.isEmpty { deliverDisplayUnits(cached) }
    }

    /// Called by `Digia.setCurrentScreen()`. Do not call manually.
    public func forwardScreen(_ name: String) {
        client.recordScreen(name)
    }

    /// Called by Digia core when an experience reports a lifecycle event.
    ///
    /// Routes by channel: a trigger carrying a `displayUnitId` came from Native
    /// Display and is reported straight back to CleverTap, everything else
    /// belongs to the custom-template slot.
    public func notifyEvent(_ event: DigiaExperienceEvent, payload: CEPTriggerPayload) {
        if let unitId = payload.cepMetadata[CleverTapPayloadMapper.metadataDisplayUnitId], !unitId.isEmpty {
            trackDisplayUnit(event, unitId: unitId)
            return
        }

        guard let slot else { return }
        switch event {
        case .impressed: slot.onDigiaImpressed(payload)
        case .clicked: slot.onDigiaClicked(payload)
        case .dismissed: slot.onDigiaDismissed(payload)
        }
    }

    /// Called by Digia core on unregister or replacement. Do not call manually.
    public func teardown() {
        // Free the slot before anything else is dismantled. Digia core does not
        // settle a plugin's live presentations before detaching it, so this is
        // the last moment the in-app slot can be recovered.
        slot?.teardown()
        CleverTapTemplates.detach(self)
        client.setDisplayUnitListener(nil)

        slot = nil
        delegate = nil
        pendingDisplayUnits = []
        isSetup = false
    }

    public func healthCheck() -> DiagnosticReport {
        let delegateAttached = delegate != nil
        let instanceAvailable = client.hasInstance()
        let healthy = isSetup && delegateAttached && instanceAvailable
        return DiagnosticReport(
            isHealthy: healthy,
            issue: healthy ? nil
                : (!isSetup || !delegateAttached)
                    ? "clevertap plugin not registered with Digia"
                    : "no CleverTap instance available",
            resolution: healthy ? nil
                : (!isSetup || !delegateAttached)
                    ? "call Digia.register(DigiaCleverTapPlugin())"
                    : "initialise CleverTap before registering the plugin",
            metadata: [
                "identifier": identifier,
                "isSetup": String(isSetup),
                "delegateAttached": String(delegateAttached),
                "cleverTapAvailable": String(instanceAvailable),
                "activePresentation": slot?.activePresentation?.id ?? "none",
                "activeCampaignKey": slot?.activePresentation?.trigger.campaignKey ?? "none",
            ]
        )
    }

    // MARK: - TemplateSink

    func onTemplatePresented(_ handle: TemplateHandle) {
        guard let slot, delegate != nil else {
            // Cannot deliver, so the invocation must be handed back immediately —
            // holding it would stall every later in-app (`clevertap.md` §9.6).
            Log.warn("'\(handle.templateName)' presented with no Digia delegate — freeing the slot")
            handle.setDismissed()
            return
        }

        guard let trigger = mapper.mapTemplate(handle) else {
            Log.warn(
                "'\(handle.templateName)' carries no \(CleverTapTemplates.argCampaignKey) "
                    + "— freeing the slot without rendering"
            )
            slot.settledPresentation(
                trigger: CEPTriggerPayload(
                    cepCampaignId: handle.templateName,
                    campaignKey: "",
                    cepMetadata: [CleverTapPayloadMapper.metadataTemplateName: handle.templateName]
                ),
                outcome: .dropped(reason: .missingCampaignKey),
                handle: handle
            )
            return
        }

        Log.info("'\(handle.templateName)' presented → delivering key='\(trigger.campaignKey)'")
        slot.deliver(handle: handle, trigger: trigger)
    }

    func onTemplateClosed(_ handle: TemplateHandle) {
        guard let slot else {
            handle.setDismissed()
            return
        }
        slot.onCleverTapClose(handle)
    }

    // MARK: - Native Display

    private func installDisplayUnitListener() {
        client.setDisplayUnitListener { [weak self] units in
            self?.onDisplayUnitsLoaded(units)
        }
    }

    private func onDisplayUnitsLoaded(_ units: [DisplayUnit]) {
        guard !units.isEmpty else { return }
        guard delegate != nil else {
            pendingDisplayUnits.append(contentsOf: units)
            Log.info("buffering \(units.count) Display Unit(s) received before setup")
            return
        }
        deliverDisplayUnits(units)
    }

    /// Hands mapped units to Digia.
    ///
    /// Every delivery of a unit is dispatched, including a repeat of one already
    /// seen: CleverTap re-delivers its active units on each refresh, and
    /// de-duplicating here would silently drop a legitimate re-trigger. The
    /// verdict is deliberately ignored — Native Display holds no slot, so a
    /// declined unit costs nothing and needs no release.
    private func deliverDisplayUnits(_ units: [DisplayUnit]) {
        guard let delegate else { return }
        let triggers = mapper.mapDisplayUnits(units)
        guard !triggers.isEmpty else { return }
        Log.info("delivering \(triggers.count) Native Display campaign(s)")
        for trigger in triggers {
            _ = delegate.onCampaignTriggered(trigger)
        }
    }

    /// Reports a Native Display view or click back to CleverTap.
    ///
    /// CleverTap never infers these — a Display Unit has no impression until the
    /// app says so (`clevertap.md` §12.8). Dismissal has no CleverTap
    /// counterpart: Native Display has no slot to release and no close event to
    /// record.
    private func trackDisplayUnit(_ event: DigiaExperienceEvent, unitId: String) {
        switch event {
        case .impressed:
            client.pushDisplayUnitViewed(unitId)
            Log.info("Native Display view reported for '\(unitId)'")
        case .clicked:
            client.pushDisplayUnitClicked(unitId)
            Log.info("Native Display click reported for '\(unitId)'")
        case .dismissed:
            break
        }
    }

    // MARK: - Static setup helpers

    /// Registers `DigiaTemplate` and `DigiaPrimaryClick` with CleverTap.
    ///
    /// Call from `application(_:didFinishLaunchingWithOptions:)` **before**
    /// CleverTap initialises. CleverTap resolves custom templates when its
    /// instance is created and filters out campaigns whose template is not
    /// registered, so a late call silently loses every custom-template campaign
    /// already in flight.
    ///
    /// Idempotent and safe to call more than once.
    public static func prepareCleverTapCustomTemplates() {
        CleverTapTemplates.register()
    }

    /// Uploads the local template definitions to the CleverTap dashboard.
    ///
    /// Debug configurations sync automatically on registration; this exists for
    /// the case where a release-configuration build needs to push definitions.
    public static func syncCleverTapCustomTemplates(isProduction: Bool = false) {
        CleverTapSdkClient().syncRegisteredTemplates(isProduction: isProduction)
    }
}
