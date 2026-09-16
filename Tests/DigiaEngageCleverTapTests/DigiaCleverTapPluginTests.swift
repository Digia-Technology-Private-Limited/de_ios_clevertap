@testable import DigiaEngage
@testable import DigiaEngageCleverTap
import Foundation
import Testing

/// Everything one test needs, held together.
///
/// A single binding keeps all of it alive for the test's scope. That matters:
/// the plugin holds its Digia delegate **weakly** (core owns the delegate, and a
/// strong reference would be a cycle), so a test that let its delegate go out of
/// scope would silently exercise the no-delegate path and pass for the wrong
/// reason.
@MainActor
private final class Harness {
    let client: FakeCleverTapClient
    let delegate: FakeDigiaDelegate
    let watchdog: ManualWatchdogScheduler
    let plugin: DigiaCleverTapPlugin

    init(
        client: FakeCleverTapClient = FakeCleverTapClient(),
        delegate: FakeDigiaDelegate = FakeDigiaDelegate(),
        watchdog: ManualWatchdogScheduler = ManualWatchdogScheduler(),
        setUp: Bool = true
    ) {
        self.client = client
        self.delegate = delegate
        self.watchdog = watchdog
        self.plugin = DigiaCleverTapPlugin(client: client, watchdogScheduler: watchdog)
        if setUp { plugin.setup(delegate: delegate) }
    }

    /// The trigger Digia most recently received.
    var lastTrigger: CEPTriggerPayload { delegate.triggered[delegate.triggered.count - 1] }
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

    @Test("frees the slot when Digia declines the campaign")
    func freesSlotWhenDigiaDeclines() {
        // The F1 scenario: a frequency-capped campaign. Digia answers false and
        // emits no dismiss event, so if the plugin ignored the verdict the slot
        // would stay held for the whole session.
        let h = Harness(delegate: FakeDigiaDelegate(accept: false))
        let handle = FakeTemplateHandle()

        h.plugin.onTemplatePresented(handle)

        #expect(h.delegate.triggered.count == 1, "Digia must actually have been asked")
        #expect(handle.dismissedCount == 1, "slot must be freed")
        #expect(handle.presentedCount == 0, "a declined campaign was never seen")
    }

    @Test("frees the slot when the template carries no campaign key")
    func freesSlotWhenCampaignKeyMissing() {
        let h = Harness()
        let handle = FakeTemplateHandle(campaignKey: "   ")

        h.plugin.onTemplatePresented(handle)

        #expect(handle.dismissedCount == 1)
        #expect(h.delegate.triggered.isEmpty, "nothing should reach Digia")
    }

    @Test("frees the slot when no Digia delegate is attached")
    func freesSlotWithoutDelegate() {
        // Never set up — mirrors a template presenting before Digia.register().
        let h = Harness(setUp: false)
        let handle = FakeTemplateHandle()

        h.plugin.onTemplatePresented(handle)

        #expect(handle.dismissedCount == 1)
    }

    @Test("watchdog frees the slot when Digia never reports anything")
    func watchdogFreesSlot() {
        let h = Harness()
        let handle = FakeTemplateHandle()
        h.plugin.onTemplatePresented(handle)
        #expect(h.delegate.triggered.count == 1)
        #expect(handle.dismissedCount == 0, "accepted, so still held")

        h.watchdog.fireAll()

        #expect(handle.dismissedCount == 1, "watchdog must free the slot")
    }

    // MARK: - The happy path

    @Test("reports the view only once Digia renders, and once only")
    func reportsViewOnlyAfterRender() {
        let h = Harness()
        let handle = FakeTemplateHandle()
        h.plugin.onTemplatePresented(handle)

        #expect(handle.presentedCount == 0, "impression must not be booked before Digia renders")

        h.plugin.notifyEvent(.impressed, payload: h.lastTrigger)
        h.plugin.notifyEvent(.impressed, payload: h.lastTrigger)

        #expect(handle.presentedCount == 1)
        #expect(handle.dismissedCount == 0, "still on screen")
    }

    @Test("the watchdog is cancelled once the campaign is on screen")
    func watchdogCancelledOnDisplay() {
        let h = Harness()
        h.plugin.onTemplatePresented(FakeTemplateHandle())

        h.plugin.notifyEvent(.impressed, payload: h.lastTrigger)

        #expect(h.watchdog.pendingCount == 0, "a displayed campaign may stay up indefinitely")
    }

    @Test("frees the slot when Digia dismisses, exactly once")
    func freesSlotOnDismiss() {
        let h = Harness()
        let handle = FakeTemplateHandle()
        h.plugin.onTemplatePresented(handle)

        h.plugin.notifyEvent(.impressed, payload: h.lastTrigger)
        h.plugin.notifyEvent(.dismissed, payload: h.lastTrigger)
        h.plugin.notifyEvent(.dismissed, payload: h.lastTrigger)

        #expect(handle.dismissedCount == 1, "a repeated dismiss must not double-release")
    }

    @Test("a click triggers the campaign's primary action")
    func clickTriggersPrimaryAction() {
        let h = Harness()
        let handle = FakeTemplateHandle()
        h.plugin.onTemplatePresented(handle)

        h.plugin.notifyEvent(.impressed, payload: h.lastTrigger)
        h.plugin.notifyEvent(.clicked(elementID: "cta"), payload: h.lastTrigger)

        #expect(handle.triggeredActions == [TemplateSlot.primaryActionArgument])
    }

    // MARK: - Terminal paths driven from outside Digia

    @Test("a CleverTap close frees the slot and invalidates the Digia campaign")
    func cleverTapCloseInvalidates() {
        let h = Harness()
        let handle = FakeTemplateHandle()
        h.plugin.onTemplatePresented(handle)

        h.plugin.onTemplateClosed(handle)

        #expect(handle.dismissedCount == 1)
        #expect(h.delegate.invalidated == ["onboarding_tip"])
    }

    @Test("teardown while a campaign is live frees the slot")
    func teardownFreesSlot() {
        let h = Harness()
        let handle = FakeTemplateHandle()
        h.plugin.onTemplatePresented(handle)
        #expect(h.delegate.triggered.count == 1, "the campaign really took the slot")

        h.plugin.teardown()

        #expect(handle.dismissedCount == 1, "unregistering must not strand the slot")
    }

    @Test("a dismiss for a campaign that does not hold the slot is ignored")
    func foreignDismissIgnored() {
        let h = Harness()
        let handle = FakeTemplateHandle()
        h.plugin.onTemplatePresented(handle)

        h.plugin.notifyEvent(
            .dismissed,
            payload: CEPTriggerPayload(
                cepCampaignId: "some_other_campaign",
                campaignKey: h.lastTrigger.campaignKey,
                cepMetadata: h.lastTrigger.cepMetadata
            )
        )

        #expect(handle.dismissedCount == 0, "the live campaign must keep the slot")
    }

    // MARK: - Re-entrancy

    @Test("the next queued template can present from inside the release")
    func reentrantPresentDuringRelease() {
        // CleverTap pumps the next queued in-app synchronously from dismissed(),
        // so releasing one campaign can re-enter the presenter with the next.
        let h = Harness(delegate: FakeDigiaDelegate(accept: false))
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
    func nativeDisplayReporting() {
        let h = Harness()

        h.client.emitDisplayUnits([displayUnit("unit_1", campaignKey: "promo_banner")])

        h.plugin.notifyEvent(.impressed, payload: h.lastTrigger)
        h.plugin.notifyEvent(.clicked(elementID: nil), payload: h.lastTrigger)
        h.plugin.notifyEvent(.dismissed, payload: h.lastTrigger)

        #expect(h.client.viewedUnits == ["unit_1"])
        #expect(h.client.clickedUnits == ["unit_1"])
    }

    @Test("Display Units received before setup are flushed on setup")
    func displayUnitsBufferedBeforeSetup() {
        let h = Harness(setUp: false)

        // The listener is live from construction, so an app-launch batch that
        // arrives while Digia.initialize() is still running is not lost.
        h.client.emitDisplayUnits([displayUnit("early_unit", campaignKey: "launch_promo")])
        #expect(h.delegate.triggered.isEmpty, "buffered, not delivered yet")

        h.plugin.setup(delegate: h.delegate)

        #expect(h.delegate.triggered.map(\.cepCampaignId) == ["early_unit"])
    }

    @Test("cached Display Units are replayed on setup")
    func cachedDisplayUnitsReplayed() {
        let h = Harness(client: FakeCleverTapClient(cached: [displayUnit("cached_unit", campaignKey: "cached_promo")]))

        #expect(h.delegate.triggered.map(\.cepCampaignId) == ["cached_unit"])
    }

    @Test("every delivery of a unit is dispatched, including repeats")
    func repeatedDeliveriesDispatched() {
        let h = Harness()
        let unit = displayUnit("repeat_unit", campaignKey: "repeat_promo")

        h.client.emitDisplayUnits([unit])
        h.client.emitDisplayUnits([unit])

        #expect(h.delegate.triggered.count == 2, "re-delivery is a legitimate re-trigger")
    }

    @Test("a declined Display Unit needs no release")
    func declinedDisplayUnitNeedsNoRelease() {
        let h = Harness(delegate: FakeDigiaDelegate(accept: false))

        h.client.emitDisplayUnits([displayUnit("declined_unit", campaignKey: "declined_promo")])

        #expect(h.delegate.triggered.count == 1, "it really was offered to Digia")
        #expect(h.client.viewedUnits.isEmpty, "Native Display holds no slot")
    }

    // MARK: - Wiring

    @Test("screen changes reach CleverTap")
    func screenChangesForwarded() {
        let h = Harness()

        h.plugin.forwardScreen("Checkout")

        #expect(h.client.recordedScreens == ["Checkout"])
    }

    @Test("health reports the live campaign and clears after teardown")
    func healthReportsLiveCampaign() {
        let h = Harness()
        h.plugin.onTemplatePresented(FakeTemplateHandle())

        let live = h.plugin.healthCheck()
        #expect(live.isHealthy)
        #expect(live.metadata["activeCampaignKey"] == "onboarding_tip")

        h.plugin.teardown()
        #expect(h.plugin.healthCheck().metadata["activeCampaignKey"] == "none")
    }

    @Test("health reports unhealthy when CleverTap is unavailable")
    func healthUnhealthyWithoutCleverTap() {
        let client = FakeCleverTapClient()
        client.instanceAvailable = false
        let h = Harness(client: client)

        #expect(!h.plugin.healthCheck().isHealthy)
    }

    @Test("setup is idempotent")
    func setupIsIdempotent() {
        let h = Harness()

        h.plugin.setup(delegate: h.delegate)

        h.client.emitDisplayUnits([displayUnit("unit_1", campaignKey: "promo")])
        #expect(h.delegate.triggered.count == 1, "a second setup must not double-deliver")
    }
}
