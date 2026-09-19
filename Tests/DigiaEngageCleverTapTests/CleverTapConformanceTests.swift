@testable import DigiaEngage
@testable import DigiaEngageCleverTap
import Foundation
import Testing

@MainActor
private final class Harness {
    let client: FakeCleverTapClient
    let host: FakeCEPHost
    let plugin: DigiaCleverTapPlugin

    init(host: FakeCEPHost = FakeCEPHost()) {
        self.client = FakeCleverTapClient()
        self.host = host
        self.plugin = DigiaCleverTapPlugin(client: client)
        plugin.attach(host: host)
    }

    /// Core's write face for the most recent delivery.
    var core: PresentationController { host.last }
}

/// The plugin conformance kit — spec §8.3.
///
/// One scenario table, run against all six plugin targets (Swift × 3,
/// Kotlin × 3). **The test names are the shared vocabulary**: `C4` means the
/// same thing in `ios/moengage` as it does in `android/clevertap`, so a row that
/// is green on five targets and red on one names the divergence by itself.
/// Never rename one without renaming all six.
///
/// Every scenario asks the same question in CleverTap's terms: **was the visual
/// in-app slot handed back, exactly once?** A `DigiaTemplate` invocation that
/// takes the slot and never dismisses stalls every later in-app in the
/// customer's app — theirs as much as ours — for the rest of the session.
@MainActor
@Suite("DigiaCleverTapPlugin — CEP conformance (spec §8.3)", .serialized)
struct CleverTapConformanceTests {

    @Test("C1 — deliver then dismissed: exactly one release, after the dismiss")
    func c1DismissedReleasesOnceAfterTheDismiss() async {
        let h = Harness()
        let handle = FakeTemplateHandle()
        h.plugin.onTemplatePresented(handle)

        h.core.markDisplaying()
        #expect(handle.presentedCount == 1)
        #expect(handle.dismissedCount == 0, "the slot is still held while it is on screen")

        h.core.settle(.dismissed(reason: .userClose, completed: false))
        await drainMainActor()

        #expect(handle.dismissedCount == 1)
        #expect(h.core.isHoldReleased, "G8: the hold cannot outlive the outcome")
    }

    @Test("C2 — deliver then dropped: exactly one release")
    func c2DroppedReleasesOnce() async {
        let h = Harness()
        let handle = FakeTemplateHandle()
        h.plugin.onTemplatePresented(handle)

        h.core.settle(.dropped(reason: .frequencyCapped, detail: nil))
        await drainMainActor()

        #expect(handle.dismissedCount == 1, "a drop frees the slot exactly like a dismissal")
        #expect(handle.presentedCount == 0, "a dropped campaign was never seen")
        #expect(h.core.isHoldReleased)
    }

    @Test("C3 — outcome delayed, then cancel() from the CEP close: one release, idempotent")
    func c3CepCloseCancelsIdempotently() async {
        let h = Harness()
        let handle = FakeTemplateHandle()
        h.plugin.onTemplatePresented(handle)
        h.core.markDisplaying()

        // CleverTap closed the template while Digia was still displaying it —
        // the CEP-initiated termination, which reaches core as `cancel()`.
        h.plugin.onTemplateClosed(handle)

        #expect(handle.dismissedCount == 1)
        #expect(h.core.isSettled)
        #expect(
            h.core.presentation.outcome.settledValue == .dismissed(reason: .cancelled, completed: false)
        )

        // G5: `cancel()` is idempotent and safe in any state, settled included.
        h.core.presentation.cancel()
        await drainMainActor()

        #expect(handle.dismissedCount == 1, "a repeated cancel must not double-release")
    }

    @Test("C4 — plugin unregistered mid-display still releases")
    func c4DetachMidDisplayStillReleases() async {
        // Asserted as a *fact*, not as a code path: after the unregister the
        // CEP's slot is not held, exactly once. That stays true under both
        // designs currently on the table — the iOS `detach()` backstop that
        // releases in-flight presentations, and the pure-G6 form where core
        // settling `plugin_detached` is the only thing that frees it. The two
        // are driven here in the order G6 specifies (settle, then detach) with
        // no drain in between, which is also the race between them.
        let h = Harness()
        let handle = FakeTemplateHandle()
        h.plugin.onTemplatePresented(handle)
        h.core.markDisplaying()

        h.host.settleOwnedPresentations()
        h.plugin.detach()
        await drainMainActor()

        #expect(handle.dismissedCount == 1, "unregistering must free the slot, and free it once")
        #expect(
            h.core.presentation.outcome.settledValue
                == .dismissed(reason: .pluginDetached, completed: false)
        )
    }

    @Test("C5 — a throwing CEP release call is swallowed, with no crash and no lost release")
    func c5MisbehavingReleaseCall() async {
        // platform note: Swift cannot express the Kotlin twin's literal form.
        // `setDismissed()` is non-throwing by type, an Obj-C exception out of
        // CleverTap is not catchable in Swift, and a Swift trap is fatal by
        // design — there is nothing to swallow. iOS is structurally safe for the
        // half the Kotlin fix addressed: `PresentationPromise.settle` resumes
        // continuations and the plugin code awaiting them runs on its own task,
        // so a plugin's completion handler never runs inside core's settle stack
        // and cannot unwind into it.
        //
        // What *is* expressible, and is asserted here, is the rest of the row:
        // the CEP's release call re-enters core from inside the release, and
        // neither the release nor the first outcome is lost — the slot really is
        // free afterwards, which the second template proves.
        let h = Harness()
        let handle = FakeTemplateHandle()
        h.plugin.onTemplatePresented(handle)
        h.core.markDisplaying()

        let core = h.core
        handle.onDismissed = {
            core.presentation.cancel()
            core.settle(.dropped(reason: .error, detail: "re-entrant settle from the CEP"))
        }

        h.core.settle(.dismissed(reason: .userClose, completed: false))
        await drainMainActor()

        #expect(handle.dismissedCount == 1)
        #expect(
            core.presentation.outcome.settledValue == .dismissed(reason: .userClose, completed: false),
            "the first outcome stands — G1"
        )

        let next = FakeTemplateHandle(campaignKey: "next_campaign")
        h.plugin.onTemplatePresented(next)
        #expect(h.host.delivered.count == 2, "the slot was genuinely free afterwards")
    }

    @Test("C6 — re-trigger the same campaignKey while the first is live: two presentations, two releases")
    func c6ReTriggerSameCampaignKey() async {
        // The `cepCampaignId` collision the contract calls out: CleverTap's
        // template channel has no per-invocation id, so the mapper puts the
        // campaign key there and a re-trigger of one campaign carries the very
        // same value. Identity is `CampaignPresentation.id` precisely because of
        // this.
        let h = Harness()
        let first = FakeTemplateHandle(campaignKey: "promo")
        let second = FakeTemplateHandle(campaignKey: "promo")

        h.plugin.onTemplatePresented(first)
        h.plugin.onTemplatePresented(second)

        #expect(h.host.delivered.count == 2)
        #expect(
            h.host.delivered[0].cepCampaignId == h.host.delivered[1].cepCampaignId,
            "the CEP's own id really does collide — that is the point"
        )
        #expect(
            h.host.controllers[0].id != h.host.controllers[1].id,
            "two genuinely distinct presentations"
        )
        #expect(first.dismissedCount == 1, "the incumbent was released when it was superseded")
        #expect(second.dismissedCount == 0, "the newcomer holds the slot now")

        h.core.markDisplaying()
        h.core.settle(.dismissed(reason: .userClose, completed: false))
        await drainMainActor()

        #expect(second.dismissedCount == 1, "two presentations, two releases")
    }

    @Test("C7 — hold released early: one unblock, clicked still marked, final marking at outcome")
    func c7EarlyHoldRelease() async {
        let h = Harness()
        let handle = FakeTemplateHandle()
        h.plugin.onTemplatePresented(handle)
        h.core.markDisplaying()

        h.core.releaseHold()
        await drainMainActor()

        #expect(handle.dismissedCount == 1, "the slot is handed back the moment the hold ends")

        // platform note, and a finding rather than a passing row: CleverTap
        // cannot mark a click after the early release. `setDismissed()` is
        // terminal for a template invocation, so `triggerAction` on it is no
        // longer legal — the plugin unsubscribes from signals as it releases.
        // The spec's "clicked after it still marked" is therefore unreachable on
        // this channel, by CleverTap's own rules rather than by an omission
        // here. WebEngage and MoEngage, whose marking outlives their hold, do
        // assert it.
        h.core.emitClicked(elementId: "cta")
        #expect(handle.triggeredActions.isEmpty)

        h.core.settle(.dismissed(reason: .screenExit, completed: true))
        await drainMainActor()

        #expect(handle.dismissedCount == 1, "exactly one unblock, not one per phase")
    }

    @Test("C8 — sync drop with the unblock bound after the fact still fires")
    func c8SyncDropLateAwaiter() async {
        // Regression guard for `PresentationPromise` collapsing back into a
        // fire-and-forget signal. The plugin's own path would survive that — it
        // peeks at `isSettled` before awaiting — so the late awaiter below is
        // the assertion that actually catches it.
        let h = Harness(host: FakeCEPHost(syncDrop: .frequencyCapped))
        let handle = FakeTemplateHandle()

        h.plugin.onTemplatePresented(handle)

        #expect(h.host.delivered.count == 1, "Digia must actually have been asked")
        #expect(handle.dismissedCount == 1, "released inline, with no turn of the main actor")
        #expect(h.core.isHoldReleased, "G8: the hold settled no later than the outcome")

        let fired = await awaiterAttachedLateFires(h.core.presentation.holdReleased)
        #expect(fired, "a late awaiter must still fire — a missed release wedges the CEP queue")
    }
}
