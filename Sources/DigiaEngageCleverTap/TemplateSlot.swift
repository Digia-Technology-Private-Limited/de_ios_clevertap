import DigiaEngage
import Foundation

/// Guards CleverTap's single global visual in-app slot.
///
/// CleverTap shows one visual in-app at a time; a `DigiaTemplate` invocation
/// holds that slot from the moment its presenter is called until `dismissed()`.
/// If a presenter takes the slot and never dismisses, **every** later in-app —
/// Digia's and the customer's alike — queues behind it for the rest of the
/// session (`docs-internal/cep-integrations/clevertap.md` §9.5). That is the
/// failure this type exists to make unreachable.
///
/// ## What v2 moved out of here
///
/// The presentation handle, its exactly-once outcome and the acceptance
/// watchdog all belong to Digia core now (``CampaignPresentation``,
/// ``PresentationController``, spec §10.5 G-d). What is left is the part that is
/// genuinely CleverTap's: hold the template handle, mark impressions and clicks,
/// and hand the slot back the instant core says the hold is over.
///
/// ## The release funnel, and why it is not just `await holdReleased`
///
/// The contract's one-liner is `await presentation.holdReleased.value; release()`.
/// This type keeps that binding but funnels it — along with every other terminal
/// path — through the single private ``release(_:)``, which is the only caller of
/// `setDismissed()`. The funnel exists because the `await` cannot be the *only*
/// path:
///
/// - `deliver()` can return an **already settled** presentation (a synchronous
///   drop — unknown key, frequency capped). Its hold released before any task
///   could be scheduled, so the slot is freed inline instead.
/// - ``teardown()`` runs when the plugin is detached. Core settles what this
///   plugin owns first, but the awaiting task has not necessarily been *run* yet,
///   and `PresentationPromise` deliberately ignores task cancellation — a task
///   parked on a promise core never settles never resumes at all. A release path
///   that depended on that task surviving detach would strand the slot
///   permanently, which is the original F1 bug wearing a new hat.
///
/// So: one funnel, three entry points (the awaited hold, the synchronous drop,
/// teardown), and `release` idempotent so they can all fire.
///
/// Main-actor confined: CleverTap invokes template presenters on the main
/// thread, and the whole v2 contract is `@MainActor`.
@MainActor
final class TemplateSlot {

    /// Name of the template's action argument, carrying the campaign author's
    /// primary click-through. Must match the `DigiaTemplate` definition in
    /// ``CleverTapTemplates`` and on the CleverTap dashboard.
    nonisolated static let primaryActionArgument = "action"

    /// One campaign holding the slot, with everything needed to free it.
    private final class Entry {
        let presentation: CampaignPresentation
        let handle: TemplateHandle
        var unsubscribe: (@MainActor () -> Void)?
        var holdWaiter: Task<Void, Never>?
        var released = false

        init(presentation: CampaignPresentation, handle: TemplateHandle) {
            self.presentation = presentation
            self.handle = handle
        }
    }

    private var active: Entry?

    private let host: DigiaCEPHost
    private let onReleased: (CampaignPresentation) -> Void

    /// Non-nil while a campaign holds the slot. Diagnostics only.
    var activePresentation: CampaignPresentation? { active?.presentation }

    /// - Parameters:
    ///   - host: the door into Digia core, handed to the plugin at `attach`.
    ///   - onReleased: notified after the slot is freed, for diagnostics.
    init(
        host: DigiaCEPHost,
        onReleased: @escaping (CampaignPresentation) -> Void = { _ in }
    ) {
        self.host = host
        self.onReleased = onReleased
    }

    /// Takes the slot for `trigger` and delivers it into Digia.
    ///
    /// Total function: never throws, and always leaves the slot consistent — the
    /// invocation is either delivered and owned, or handed straight back to
    /// CleverTap. `nil` means nothing was delivered and the handle is already
    /// free.
    @discardableResult
    func deliver(handle: TemplateHandle, trigger: CEPTriggerPayload) -> CampaignPresentation? {
        // Defensive. CleverTap's one-visual-in-app rule should make an overlap
        // unreachable; if it happens anyway, freeing the incumbent beats wedging
        // the slot. `cancel()` asks core to end it properly; `release` is the
        // backstop that frees CleverTap's side whatever core does.
        if let incumbent = active {
            Log.warn("template presented while \(incumbent.presentation.id) still holds the slot — superseding it")
            incumbent.presentation.cancel()
            release(incumbent)
        }

        // Freeing the incumbent above can re-enter this method, because
        // dismissed() makes CleverTap pump the next queued in-app synchronously.
        // If that happened, the slot now belongs to that nested delivery and must
        // not be clobbered — hand this invocation straight back instead.
        if active != nil {
            Log.warn("slot was re-taken while superseding — declining '\(handle.templateName)'")
            handle.setDismissed()
            return nil
        }

        let presentation = host.deliver(trigger)
        let entry = Entry(presentation: presentation, handle: handle)
        active = entry

        // Cleared by core on settlement, so there is nothing to unsubscribe on
        // the normal path; the stored closure is for the teardown path.
        entry.unsubscribe = presentation.onSignal { [weak self] signal in
            self?.forward(signal, to: entry)
        }

        // A synchronous drop already released its hold. Free the slot inline
        // rather than waiting for a task that would only confirm what is already
        // true — and, on this path, would run after CleverTap had been left
        // holding the slot across a suspension point.
        if presentation.holdReleased.isSettled {
            Log.info("Dropped synchronously — freeing the in-app slot", campaign: trigger.campaignKey)
            release(entry)
            return presentation
        }

        // `weak self` and `weak entry`: if core never settles this presentation
        // the task parks forever (PresentationPromise ignores cancellation by
        // design), so it must not keep the plugin or the slot alive.
        entry.holdWaiter = Task { @MainActor [weak self, weak entry] in
            await presentation.holdReleased.value
            guard let self, let entry else { return }
            self.release(entry)
        }
        return presentation
    }

    /// CleverTap asked the template to close — an in-app action used the close
    /// behaviour, or the campaign was pulled. Terminal on CleverTap's side too
    /// (`clevertap.md` §9.7).
    ///
    /// Core is cancelled first so it can tear its UI down and settle the
    /// presentation; the release afterwards is the backstop for the case where
    /// core had nothing to dismiss, and is a no-op if the cancel already freed it.
    func onCleverTapClose(_ handle: TemplateHandle) {
        guard let entry = active else {
            // A close for an invocation that never took the slot. It is still a
            // live CleverTap invocation, so it must reach a terminal state here
            // or it stalls the queue exactly as a forgotten dismiss would.
            Log.info("Close for '\(handle.templateName)' with no campaign holding the slot")
            handle.setDismissed()
            return
        }
        Log.info("CleverTap closed '\(handle.templateName)' — cancelling presentation", campaign: entry.presentation.trigger.campaignKey)
        entry.presentation.cancel()
        release(entry)
    }

    /// Frees the slot because the plugin is being detached.
    ///
    /// Core settles a plugin's presentations before calling `detach()`, but the
    /// task awaiting that settlement has not necessarily run yet — and if a core
    /// ever fails to settle, nothing else would ever free CleverTap's slot. This
    /// is the last moment it can be recovered, so it is taken unconditionally.
    func teardown() {
        guard let entry = active else { return }
        Log.info("Teardown while holding the slot — freeing", campaign: entry.presentation.trigger.campaignKey)
        entry.presentation.cancel()
        release(entry)
    }

    // MARK: - Internals

    /// Reports what core says happened back to CleverTap.
    ///
    /// `displayed` is deliberately the trigger for `setPresented()` rather than
    /// the presenter firing: `presented()` records the impression and consumes
    /// frequency budget, so calling it before Digia commits would book a view for
    /// a campaign the user never saw (`clevertap.md` §9.3).
    private func forward(_ signal: PresentationSignal, to entry: Entry) {
        guard !entry.released else { return }
        switch signal {
        case .displayed:
            Log.info("CEP impression marked (setPresented)", campaign: entry.presentation.trigger.campaignKey)
            entry.handle.setPresented()
        case .clicked:
            Log.info("CEP click marked (triggerAction)", campaign: entry.presentation.trigger.campaignKey)
            entry.handle.triggerAction(named: Self.primaryActionArgument)
        }
    }

    /// The one place the slot is freed, and the only caller of `setDismissed()`.
    ///
    /// Idempotent, so every entry point above can call it without checking.
    /// Ordered so the slot reads as free *before* CleverTap is told, because
    /// `dismissed()` synchronously pumps the next queued in-app, which can
    /// re-enter ``deliver(handle:trigger:)`` from inside this call.
    private func release(_ entry: Entry) {
        guard !entry.released else { return }
        entry.released = true

        entry.unsubscribe?()
        entry.unsubscribe = nil
        entry.holdWaiter?.cancel()
        entry.holdWaiter = nil
        if active === entry { active = nil }

        entry.handle.setDismissed()
        Log.info("CEP hold released (setDismissed, state=\(entry.presentation.state.value))", campaign: entry.presentation.trigger.campaignKey)
        onReleased(entry.presentation)
    }
}
