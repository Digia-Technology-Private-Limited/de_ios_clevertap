@testable import DigiaEngage
@testable import DigiaEngageCleverTap
import Foundation
import Testing

/// Everything one test needs, held together.
///
/// A single binding keeps all of it alive for the test's scope. That matters:
/// the plugin holds its ``DigiaCEPHost`` weakly-in-spirit (core owns the host),
/// and the fake host owns the `PresentationController`s the tests drive, so a
/// harness that went out of scope would silently exercise the no-host path and
/// pass for the wrong reason.
@MainActor
private final class Harness {
    let client: FakeCleverTapClient
    let host: FakeCEPHost
    let plugin: DigiaCleverTapPlugin

    init(
        client: FakeCleverTapClient = FakeCleverTapClient(),
        host: FakeCEPHost = FakeCEPHost(),
        attach: Bool = true
    ) {
        self.client = client
        self.host = host
        self.plugin = DigiaCleverTapPlugin(client: client)
        if attach { plugin.attach(host: host) }
    }

    /// The trigger Digia most recently received.
    var lastTrigger: CEPTriggerPayload { host.delivered[host.delivered.count - 1] }

    /// Core's write face for the most recent delivery.
    var core: PresentationController { host.last }
}

/// Lifecycle tests for CleverTap's single visual in-app slot.
///
/// Every test here is ultimately asking one question: **was the slot freed?**
/// A `DigiaTemplate` invocation that takes the slot and never dismisses stalls
/// every later in-app in the customer's app — Digia's and their own — for the
/// rest of the session. The scenarios mirror the Android plugin's suite and the
/// React Native plugin's, which is the behaviour this port is held to.
@MainActor
@Suite("DigiaCleverTapPlugin — in-app slot lifecycle", .serialized)
struct DigiaCleverTapPluginTests {

    // MARK: - The drop paths: every one of them must free the slot

    @Test("frees the slot when Digia drops the campaign")
    func freesSlotWhenDigiaDrops() {
        // The F1 scenario: a frequency-capped campaign. Core settles inside
        // deliver() and emits nothing afterwards, so a plugin that waited for a
        // lifecycle event would hold the slot for the whole session.
        let h = Harness(host: FakeCEPHost(syncDrop: .frequencyCapped))
        let handle = FakeTemplateHandle()

        h.plugin.onTemplatePresented(handle)

        #expect(h.host.delivered.count == 1, "Digia must actually have been asked")
        #expect(handle.dismissedCount == 1, "slot must be freed")
        #expect(handle.presentedCount == 0, "a dropped campaign was never seen")
    }

    @Test("frees the slot when the template carries no campaign key")
    func freesSlotWhenCampaignKeyMissing() {
        let h = Harness()
        let handle = FakeTemplateHandle(campaignKey: "   ")

        h.plugin.onTemplatePresented(handle)

        #expect(handle.dismissedCount == 1)
        #expect(h.host.delivered.isEmpty, "nothing should reach Digia")
    }

    @Test("holds the template when no Digia host is attached")
    func holdsTemplateWithoutHost() {
        // Never attached — mirrors a template presenting before Digia.register().
        let h = Harness(attach: false)
        let handle = FakeTemplateHandle()

        h.plugin.onTemplatePresented(handle)

        #expect(handle.dismissedCount == 0, "buffered until Core is ready")
        h.plugin.attach(host: h.host)
        #expect(h.host.delivered.count == 1, "flushed on attach to a ready host")
    }

    @Test("core's acceptance watchdog frees the slot when nothing is ever rendered")
    func watchdogFreesSlot() async {
        // The watchdog itself moved to core at v2 (spec §10.5 G-d): the plugin's
        // only obligation is that a `timeout` drop releases the slot like any
        // other terminal outcome.
        let h = Harness()
        let handle = FakeTemplateHandle()
        h.plugin.onTemplatePresented(handle)
        #expect(h.host.delivered.count == 1)
        #expect(handle.dismissedCount == 0, "accepted, so still held")

        h.core.settle(.dropped(reason: .timeout, detail: "no verdict in time"))
        await drainMainActor()

        #expect(handle.dismissedCount == 1, "a timeout drop must free the slot")
    }

    // MARK: - The happy path

    @Test("reports the view only once Digia renders, and once only")
    func reportsViewOnlyAfterRender() {
        let h = Harness()
        let handle = FakeTemplateHandle()
        h.plugin.onTemplatePresented(handle)

        #expect(handle.presentedCount == 0, "impression must not be booked before Digia renders")

        h.core.markDisplaying()
        h.core.markDisplaying()

        #expect(handle.presentedCount == 1)
        #expect(handle.dismissedCount == 0, "still on screen")
    }

    @Test("a displayed campaign keeps the slot until its outcome settles")
    func displayedCampaignKeepsSlot() async {
        let h = Harness()
        let handle = FakeTemplateHandle()
        h.plugin.onTemplatePresented(handle)

        h.core.markDisplaying()
        await drainMainActor()

        #expect(handle.dismissedCount == 0, "a displayed campaign may stay up indefinitely")
    }

    @Test("frees the slot when Digia dismisses, exactly once")
    func freesSlotOnDismiss() async {
        let h = Harness()
        let handle = FakeTemplateHandle()
        h.plugin.onTemplatePresented(handle)

        h.core.markDisplaying()
        h.core.settle(.dismissed(reason: .userClose, completed: false))
        h.core.settle(.dismissed(reason: .userClose, completed: false))
        await drainMainActor()

        #expect(handle.dismissedCount == 1, "a repeated dismiss must not double-release")
    }

    @Test("a click triggers the campaign's primary action")
    func clickTriggersPrimaryAction() {
        let h = Harness()
        let handle = FakeTemplateHandle()
        h.plugin.onTemplatePresented(handle)

        h.core.markDisplaying()
        h.core.emitClicked(elementId: "cta")

        #expect(handle.triggeredActions == [TemplateSlot.primaryActionArgument])
    }

    // MARK: - Terminal paths driven from outside Digia

    @Test("a CleverTap close frees the slot and cancels the Digia presentation")
    func cleverTapCloseCancels() {
        let h = Harness()
        let handle = FakeTemplateHandle()
        h.plugin.onTemplatePresented(handle)

        h.plugin.onTemplateClosed(handle)

        #expect(handle.dismissedCount == 1)
        #expect(h.core.isSettled, "core must be told the experience is over")
        #expect(h.core.presentation.outcome.settledValue == .dropped(reason: .cancelled, detail: nil))
    }

    @Test("detach while a campaign is live frees the slot")
    func detachFreesSlot() {
        let h = Harness()
        let handle = FakeTemplateHandle()
        h.plugin.onTemplatePresented(handle)
        #expect(h.host.delivered.count == 1, "the campaign really took the slot")

        h.plugin.detach()

        #expect(handle.dismissedCount == 1, "unregistering must not strand the slot")
    }

    @Test("settling a campaign that does not hold the slot leaves the slot alone")
    func foreignSettlementIgnored() async {
        let h = Harness()
        let handle = FakeTemplateHandle()
        h.plugin.onTemplatePresented(handle)
        let slotHolder = h.core

        // A Native Display delivery: a second live presentation that holds no
        // slot. Ending it must not touch the template invocation.
        h.client.emitDisplayUnits([displayUnit("unit_1", campaignKey: "promo_banner")])
        h.core.settle(.dropped(reason: .screenNotTargeted, detail: nil))
        await drainMainActor()

        #expect(handle.dismissedCount == 0, "the live campaign must keep the slot")
        #expect(!slotHolder.isSettled)
    }

    // MARK: - Re-entrancy

    @Test("the next queued template can present from inside the release")
    func reentrantPresentDuringRelease() {
        // CleverTap pumps the next queued in-app synchronously from dismissed(),
        // so releasing one campaign can re-enter the presenter with the next.
        let h = Harness(host: FakeCEPHost(syncDrop: .frequencyCapped))
        let second = FakeTemplateHandle(campaignKey: "second_campaign")
        let first = FakeTemplateHandle(campaignKey: "first_campaign")
        first.onDismissed = { [plugin = h.plugin] in
            first.onDismissed = nil
            plugin.onTemplatePresented(second)
        }

        h.plugin.onTemplatePresented(first)

        #expect(first.dismissedCount == 1, "first released")
        #expect(second.dismissedCount == 1, "second released too, not stranded")
    }

    // MARK: - Native Display: reporting only, never the slot

    @Test("Native Display reports views and clicks by unit id")
    func nativeDisplayReporting() async {
        let h = Harness()

        h.client.emitDisplayUnits([displayUnit("unit_1", campaignKey: "promo_banner")])

        h.core.markDisplaying()
        h.core.emitClicked()
        h.core.settle(.dismissed(reason: .userClose, completed: true))
        await drainMainActor()

        #expect(h.client.viewedUnits == ["unit_1"])
        #expect(h.client.clickedUnits == ["unit_1"])
    }

    @Test("Display Units received before attach are flushed on attach")
    func displayUnitsBufferedBeforeAttach() {
        let h = Harness(attach: false)

        // The listener is live from construction, so an app-launch batch that
        // arrives while Digia.initialize() is still running is not lost.
        h.client.emitDisplayUnits([displayUnit("early_unit", campaignKey: "launch_promo")])
        #expect(h.host.delivered.isEmpty, "buffered, not delivered yet")

        h.plugin.attach(host: h.host)

        #expect(h.host.delivered.map(\.cepCampaignId) == ["early_unit"])
    }

    @Test("cached Display Units are replayed on attach")
    func cachedDisplayUnitsReplayed() {
        let h = Harness(client: FakeCleverTapClient(cached: [displayUnit("cached_unit", campaignKey: "cached_promo")]))

        #expect(h.host.delivered.map(\.cepCampaignId) == ["cached_unit"])
    }

    @Test("every delivery of a unit is dispatched, including repeats")
    func repeatedDeliveriesDispatched() {
        let h = Harness()
        let unit = displayUnit("repeat_unit", campaignKey: "repeat_promo")

        h.client.emitDisplayUnits([unit])
        h.client.emitDisplayUnits([unit])

        #expect(h.host.delivered.count == 2, "re-delivery is a legitimate re-trigger")
    }

    @Test("a dropped Display Unit needs no release")
    func droppedDisplayUnitNeedsNoRelease() {
        let h = Harness(host: FakeCEPHost(syncDrop: .frequencyCapped))

        h.client.emitDisplayUnits([displayUnit("dropped_unit", campaignKey: "dropped_promo")])

        #expect(h.host.delivered.count == 1, "it really was offered to Digia")
        #expect(h.client.viewedUnits.isEmpty, "Native Display holds no slot")
    }

    // MARK: - Wiring

    @Test("screen changes reach CleverTap")
    func screenChangesForwarded() {
        let h = Harness()

        h.plugin.onScreenChanged("Checkout")

        #expect(h.client.recordedScreens == ["Checkout"])
    }

    @Test("health reports the live campaign and clears after detach")
    func healthReportsLiveCampaign() {
        let h = Harness()
        h.plugin.onTemplatePresented(FakeTemplateHandle())

        let live = h.plugin.healthCheck()
        #expect(live.isHealthy)
        #expect(live.metadata["activeCampaignKey"] == "onboarding_tip")

        h.plugin.detach()
        #expect(h.plugin.healthCheck().metadata["activeCampaignKey"] == "none")
    }

    @Test("health reports unhealthy when CleverTap is unavailable")
    func healthUnhealthyWithoutCleverTap() {
        let client = FakeCleverTapClient()
        client.instanceAvailable = false
        let h = Harness(client: client)

        #expect(!h.plugin.healthCheck().isHealthy)
    }

    @Test("attach is idempotent")
    func attachIsIdempotent() {
        let h = Harness()

        h.plugin.attach(host: h.host)

        h.client.emitDisplayUnits([displayUnit("unit_1", campaignKey: "promo")])
        #expect(h.host.delivered.count == 1, "a second attach must not double-deliver")
    }
}
