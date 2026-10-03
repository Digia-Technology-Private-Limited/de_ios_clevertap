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

    /// Set by ``onHostInitFailed()``: deliver directly so Core drops and the CEP settles at once.
    private var hostFailed = false

    /// Templates held while Core is not ready. A held template keeps CleverTap's
    /// in-app slot until it flushes, expires or drops.
    private let pendingTemplates: PendingPayloadBuffer<(handle: TemplateHandle, trigger: CEPTriggerPayload)>

    /// Native Display campaigns held while Core is not ready: arrival order, one per unit id.
    private let pendingDisplayUnits: PendingPayloadBuffer<CEPTriggerPayload>

    public convenience init() {
        self.init(client: CleverTapSdkClient())
    }

    init(
        client: CleverTapClient,
        mapper: CleverTapPayloadMapper = CleverTapPayloadMapper(),
        schedule: @escaping PendingPayloadBuffer<CEPTriggerPayload>.Scheduler = PendingPayloadBuffer<CEPTriggerPayload>.mainQueueScheduler,
        now: @escaping () -> Date = Date.init
    ) {
        self.client = client
        self.mapper = mapper
        pendingTemplates = PendingPayloadBuffer(now: now, schedule: schedule) { pending, reason in
            Log.warn(
                "dropping buffered '\(pending.handle.templateName)' as \(reason.wire) — freeing the slot",
                campaign: pending.trigger.campaignKey, stage: .trigger, reason: reason
            )
            pending.handle.setDismissed()
        }
        pendingDisplayUnits = PendingPayloadBuffer(
            order: .inline(id: Self.displayUnitId), now: now, schedule: schedule
        ) { trigger, reason in
            Log.warn(
                "dropping buffered Native Display '\(Self.displayUnitId(trigger))' as \(reason.wire)",
                campaign: trigger.campaignKey, stage: .trigger, reason: reason
            )
        }

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

        if host.isReady { flushPending() }

        // Recovers units whose live callback fired before this plugin existed —
        // the native-before-wrapper race. Not campaign history: CleverTap's cache
        // holds only what is currently active (`clevertap.md` §12.6).
        onDisplayUnitsLoaded(client.cachedDisplayUnits())
        Log.info("Plugin attached")
    }

    /// Called by Digia core when it becomes ready. Do not call manually.
    public func onHostReady() {
        hostFailed = false
        flushPending()
    }

    /// Called by Digia core when initialization fails. Do not call manually.
    public func onHostInitFailed() {
        hostFailed = true
        pendingTemplates.dropAll(DropReason.initializationFailed)
        pendingDisplayUnits.dropAll(DropReason.initializationFailed)
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
        pendingTemplates.dropAll(DropReason.pluginDetached)
        pendingDisplayUnits.dropAll(DropReason.pluginDetached)
        CleverTapTemplates.detach(self)
        client.setDisplayUnitListener(nil)

        slot = nil
        host = nil
        hostFailed = false
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
        guard canDeliver else {
            Log.info("Core not ready — buffering the template", campaign: trigger.campaignKey)
            pendingTemplates.add((handle, trigger))
            return
        }
        deliverTemplate(handle: handle, trigger: trigger)
    }

    private func deliverTemplate(handle: TemplateHandle, trigger: CEPTriggerPayload) {
        guard let slot else {
            handle.setDismissed()
            return
        }
        guard !slot.deliver(handle: handle, trigger: trigger) else { return }
        Log.info("Core not ready — buffering the template again", campaign: trigger.campaignKey)
        pendingTemplates.add((handle, trigger))
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
        let triggers = mapper.mapDisplayUnits(units)
        guard canDeliver else {
            triggers.forEach(pendingDisplayUnits.add)
            Log.info("Core not ready — buffering \(triggers.count) Native Display campaign(s)")
            return
        }
        deliverDisplayUnits(triggers)
    }

    private var canDeliver: Bool { host?.isReady == true || (host != nil && hostFailed) }

    /// Delivers what was buffered: the newest template, then Native Display in arrival order.
    /// Older templates drop as surface_busy, because the slot would let the oldest win.
    private func flushPending() {
        var templates = pendingTemplates.drain()
        if !templates.isEmpty {
            let newest = templates.removeFirst()
            for older in templates {
                Log.warn(
                    "dropping buffered '\(older.handle.templateName)' as surface_busy — a newer template flushes",
                    campaign: older.trigger.campaignKey, stage: .trigger, reason: DropReason.surfaceBusy
                )
                older.handle.setDismissed()
            }
            deliverTemplate(handle: newest.handle, trigger: newest.trigger)
        }
        deliverDisplayUnits(pendingDisplayUnits.drain())
    }

    private nonisolated static func displayUnitId(_ trigger: CEPTriggerPayload) -> String {
        trigger.cepMetadata[CleverTapPayloadMapper.metadataDisplayUnitId] ?? ""
    }

    /// Hands mapped units to Digia.
    ///
    /// Every delivery of a unit is dispatched, including a repeat of one already
    /// seen: CleverTap re-delivers its active units on each refresh, and
    /// de-duplicating here would silently drop a legitimate re-trigger. Nothing
    /// binds to the outcome — Native Display holds no slot, so a dropped unit
    /// costs nothing and needs no release.
    private func deliverDisplayUnits(_ triggers: [CEPTriggerPayload]) {
        guard let host, !triggers.isEmpty else { return }
        Log.info("delivering \(triggers.count) Native Display campaign(s)")
        for trigger in triggers {
            let unitId = Self.displayUnitId(trigger)
            let presentation = host.deliver(trigger)
            if presentation.outcome.settledValue?.isHostNotReady == true {
                pendingDisplayUnits.add(trigger)
                continue
            }
            // Core drops its listeners on settlement, so this needs no
            // unsubscribe and no task — which is the whole difference between a
            // channel that holds a slot and one that only reports.
            _ = presentation.onSignal { [weak self] signal in
                self?.trackDisplayUnit(signal, unitId: unitId)
            }
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
