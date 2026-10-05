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

    public let id = "clevertap"

    private let client: CleverTapClient
    private let mapper: CleverTapPayloadMapper

    private var host: DigiaCEPHost?
    private var slot: TemplateSlot?

    /// Template triggers held while Core is not ready. CleverTap's slot stays
    /// held until each is shown or dropped.
    private lazy var pendingTemplates = PendingPayloadBuffer(
        onDrop: { [weak self] in self?.onPendingTemplateDropped($0, $1) }
    )

    /// The CleverTap handle of each held template, keyed by `cepCampaignId`.
    private var heldTemplates: [String: TemplateHandle] = [:]

    /// Display units held until Core is ready, in arrival order, one per unit.
    private lazy var pendingDisplayUnits = PendingPayloadBuffer(
        onDrop: { [weak self] in self?.onPendingDisplayUnitDropped($0, $1) },
        arrivalOrder: true
    )

    /// Core init failed: stop holding until Core is ready again.
    private var hostFailed = false

    public convenience init() {
        self.init(client: CleverTapSdkClient())
    }

    init(
        client: CleverTapClient,
        mapper: CleverTapPayloadMapper = CleverTapPayloadMapper()
    ) {
        self.client = client
        self.mapper = mapper

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
    public func attach(host: DigiaCEPHost) {
        guard self.host == nil else { return }
        self.host = host

        slot = TemplateSlot(host: host)

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

        if host.isReady { onHostReady() }

        // Recovers units whose live callback fired before this plugin existed —
        // the native-before-wrapper race. Not campaign history: CleverTap's cache
        // holds only what is currently active (`clevertap.md` §12.6).
        onDisplayUnitsLoaded(client.cachedDisplayUnits())
        Log.info("Plugin attached")
    }

    /// Called by Digia core when it becomes ready. Do not call manually.
    public func onHostReady() {
        hostFailed = false
        let templates = pendingTemplates.takeAll()
        let units = pendingDisplayUnits.takeAll()
        guard !templates.isEmpty || !units.isEmpty else { return }
        Log.info("Digia ready — flushing held payloads (templates=\(templates.count), displayUnits=\(units.count))")
        for trigger in templates {
            if let handle = heldTemplates.removeValue(forKey: trigger.cepCampaignId) {
                presentTemplate(handle, trigger)
            }
        }
        units.forEach(receiveDisplayUnit)
    }

    /// Called by Digia core when initialization fails. Do not call manually.
    public func onHostInitFailed() {
        onHostFailed()
    }

    /// Called by `Digia.setCurrentScreen()`. Do not call manually.
    public func onScreenChanged(_ screenName: String) {
        Log.debug("Screen recorded (screen=\(screenName))")
        client.recordScreen(screenName)
    }

    /// Called by Digia core on unregister or replacement. Do not call manually.
    public func detach() {
        // Free the slot before anything else is dismantled. Core settles this
        // plugin's presentations first, but the task awaiting that settlement has
        // not necessarily run yet — this is the last moment the in-app slot can
        // be recovered from inside the plugin.
        slot?.teardown()
        hostFailed = false
        pendingTemplates.dropAll(DropReason.pluginDetached)
        pendingDisplayUnits.dropAll(DropReason.pluginDetached)
        CleverTapTemplates.detach(self)
        client.setDisplayUnitListener(nil)

        slot = nil
        host = nil
        Log.info("Plugin detached")
    }

    /// Not part of ``DigiaCEPPlugin`` — a plugin-level diagnostic a host app
    /// can call directly when in-apps stop appearing.
    public func healthCheck() -> DiagnosticReport {
        let attached = host != nil
        let instanceAvailable = client.hasInstance()
        let healthy = attached && instanceAvailable
        return DiagnosticReport(
            isHealthy: healthy,
            issue: healthy ? nil
                : !attached
                    ? "clevertap plugin not registered with Digia"
                    : "no CleverTap instance available",
            resolution: healthy ? nil
                : !attached
                    ? "call Digia.register(DigiaCleverTapPlugin())"
                    : "initialise CleverTap before registering the plugin",
            metadata: [
                "id": id,
                "attached": String(attached),
                "cleverTapAvailable": String(instanceAvailable),
                "activePresentation": slot?.activePresentation?.id ?? "none",
                "activeCampaignKey": slot?.activePresentation?.trigger.campaignKey ?? "none",
            ]
        )
    }

    // MARK: - TemplateSink

    func onTemplatePresented(_ handle: TemplateHandle) {
        guard host != nil else {
            // Cannot deliver, so the invocation must be handed back immediately —
            // holding it would stall every later in-app (`clevertap.md` §9.6).
            let key = handle.string(named: CleverTapTemplates.argCampaignKey)?.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            Log.warn(
                "dropping '\(handle.templateName)' as not_ready — no Digia host attached — freeing the slot",
                campaign: (key?.isEmpty ?? true) ? nil : key,
                stage: .trigger,
                reason: DropReason.notReady
            )
            handle.setDismissed()
            return
        }

        guard let trigger = mapper.mapTemplate(handle) else {
            // Nothing to deliver: without a campaign key core has no campaign to
            // look up. Free the slot rather than deliver a trigger core could
            // only drop.
            Log.warn(
                "'\(handle.templateName)' carries no \(CleverTapTemplates.argCampaignKey) "
                    + "— freeing the slot without rendering"
            )
            handle.setDismissed()
            return
        }

        Log.info("Received (template=\(handle.templateName))", campaign: trigger.campaignKey)
        presentTemplate(handle, trigger)
    }

    /// Delivers a template, or holds it while Core is not ready.
    private func presentTemplate(_ handle: TemplateHandle, _ trigger: CEPTriggerPayload) {
        guard let host, let slot else {
            handle.setDismissed()
            return
        }
        if !hostFailed && !host.isReady {
            Log.info("Held until Digia is ready", campaign: trigger.campaignKey)
            holdTemplate(handle, trigger)
            return
        }
        _ = slot.deliver(handle: handle, trigger: trigger) { presentation in
            holdIfNotReady(presentation) { holdTemplate(handle, $0) }
        }
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
        mapper.mapDisplayUnits(units).forEach(receiveDisplayUnit)
    }

    /// Delivers a display unit, or holds it while Core is not ready.
    ///
    /// Every delivery of a unit is dispatched, including a repeat of one already
    /// seen: CleverTap re-delivers its active units on each refresh, and
    /// de-duplicating here would silently drop a legitimate re-trigger. Nothing
    /// binds to the outcome — Native Display holds no slot, so a dropped unit
    /// costs nothing and needs no release.
    private func receiveDisplayUnit(_ trigger: CEPTriggerPayload) {
        guard let host, hostFailed || host.isReady else {
            Log.info("Display unit held until Digia is ready (unitID=\(trigger.cepCampaignId))", campaign: trigger.campaignKey)
            pendingDisplayUnits.add(trigger)
            return
        }
        let unitId = trigger.cepCampaignId
        let presentation = host.deliver(trigger)
        if holdIfNotReady(presentation, hold: { pendingDisplayUnits.add($0) }) { return }
        // Core drops its listeners on settlement, so this needs no
        // unsubscribe and no task — which is the whole difference between a
        // channel that holds a slot and one that only reports.
        _ = presentation.onSignal { [weak self] signal in
            self?.trackDisplayUnit(signal, unitId: unitId)
        }
    }

    /// Reports a Native Display view or click back to CleverTap.
    ///
    /// CleverTap never infers these — a Display Unit has no impression until the
    /// app says so (`clevertap.md` §12.8). Dismissal has no CleverTap
    /// counterpart: Native Display has no slot to release and no close event to
    /// record, which is why nothing here binds to the outcome.
    private func trackDisplayUnit(_ signal: PresentationSignal, unitId: String) {
        guard !unitId.isEmpty else { return }
        switch signal {
        case .displayed:
            client.pushDisplayUnitViewed(unitId)
            Log.info("Native Display view reported for '\(unitId)'")
        case .clicked:
            client.pushDisplayUnitClicked(unitId)
            Log.info("Native Display click reported for '\(unitId)'")
        }
    }

    // MARK: - Pending buffer

    /// Holds a not-ready payload again and returns true; stops holding on
    /// initialization_failed.
    private func holdIfNotReady(
        _ presentation: CampaignPresentation,
        hold: (CEPTriggerPayload) -> Void
    ) -> Bool {
        guard case .dropped(let reason, _)? = presentation.outcome.settledValue else { return false }
        switch reason {
        case .notReady where !hostFailed, .notInitialized where !hostFailed:
            Log.info("Digia not ready — held again (reason=\(reason.wire))", campaign: presentation.trigger.campaignKey)
            hold(presentation.trigger)
            return true
        case .initializationFailed:
            onHostFailed()
        default:
            break
        }
        return false
    }

    private func holdTemplate(_ handle: TemplateHandle, _ trigger: CEPTriggerPayload) {
        heldTemplates[trigger.cepCampaignId] = handle
        pendingTemplates.add(trigger)
    }

    private func onHostFailed() {
        guard !hostFailed else { return }
        hostFailed = true
        pendingTemplates.dropAll(DropReason.initializationFailed)
        pendingDisplayUnits.dropAll(DropReason.initializationFailed)
    }

    private func onPendingTemplateDropped(_ trigger: CEPTriggerPayload, _ reason: DropReason) {
        Log.warn(
            "Dropped while held; freeing the in-app slot",
            campaign: trigger.campaignKey, stage: .trigger, reason: reason
        )
        heldTemplates.removeValue(forKey: trigger.cepCampaignId)?.setDismissed()
    }

    private func onPendingDisplayUnitDropped(_ trigger: CEPTriggerPayload, _ reason: DropReason) {
        Log.warn(
            "Display unit dropped while held (unitID=\(trigger.cepCampaignId))",
            campaign: trigger.campaignKey, stage: .trigger, reason: reason
        )
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
