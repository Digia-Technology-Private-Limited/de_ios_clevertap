import DigiaEngage
import Foundation

/// Cancels a scheduled watchdog.
@MainActor
final class WatchdogHandle {
    private let onCancel: () -> Void

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() { onCancel() }
}

/// Schedules the acceptance watchdog.
///
/// Injected so tests drive the timeout directly instead of waiting real seconds.
@MainActor
protocol WatchdogScheduling: AnyObject {
    func schedule(after seconds: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> WatchdogHandle
}

/// Production scheduler, backed by a cancellable `Task`.
@MainActor
final class TaskWatchdogScheduler: WatchdogScheduling {
    func schedule(after seconds: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> WatchdogHandle {
        let task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            fire()
        }
        return WatchdogHandle { task.cancel() }
    }
}

/// Guards CleverTap's single global visual in-app slot.
///
/// CleverTap shows one visual in-app at a time; a `DigiaTemplate` invocation
/// holds that slot from the moment its presenter is called until `dismissed()`.
/// If a presenter takes the slot and never dismisses, **every** later in-app —
/// Digia's and the customer's alike — queues behind it for the rest of the
/// session (`docs-internal/cep-integrations/clevertap.md` §9.5). That is the
/// failure this type exists to make unreachable.
///
/// ## The single funnel
///
/// This is the only writer of presentation state. Every terminal path — Digia
/// declining, Digia dismissing, CleverTap closing, the plugin tearing down, an
/// error, the watchdog — reaches the slot through the one private ``settle``,
/// and ``settle`` is the only caller of ``release``. There is no second way to
/// free the slot and no way to reach a terminal state without freeing it, so "a
/// path that forgot to release" is not a bug that can be written here.
///
/// The v2 spec expresses this by binding release to a promise
/// (`presentation.outcome.finally(release)`). Binding to *settlement* instead
/// gives the same guarantee — one place, unskippable — without making the
/// release depend on a task resuming, which is exactly what would fail at
/// teardown. This mirrors the Kotlin plugin's `TemplateSlot` line for line.
///
/// Main-actor confined: CleverTap invokes template presenters on the main
/// thread, and Digia core requires the same.
@MainActor
final class TemplateSlot {

    /// Name of the template's action argument, carrying the campaign author's
    /// primary click-through. Must match the `DigiaTemplate` definition in
    /// ``CleverTapTemplates`` and on the CleverTap dashboard.
    nonisolated static let primaryActionArgument = "action"

    /// Acceptance watchdog ceiling, per the Core ↔ CEP Interface v2 spec.
    nonisolated static let defaultAcceptanceTimeout: TimeInterval = 15

    /// The presentation holding the slot, with everything needed to free it.
    private final class Entry {
        let presentation: CampaignPresentation
        let handle: TemplateHandle
        var watchdog: WatchdogHandle?

        init(presentation: CampaignPresentation, handle: TemplateHandle) {
            self.presentation = presentation
            self.handle = handle
        }
    }

    private var active: Entry?
    private var deliveryCount = 0

    private let acceptanceTimeout: TimeInterval
    private let watchdogScheduler: WatchdogScheduling
    private let onDeliver: (CEPTriggerPayload) -> Bool
    private let onInvalidate: (String) -> Void
    private let onReleased: (CampaignPresentation, PresentationOutcome) -> Void

    /// Non-nil while a campaign holds the slot. Diagnostics only.
    var activePresentation: CampaignPresentation? { active?.presentation }

    /// - Parameters:
    ///   - acceptanceTimeout: how long a delivered-but-not-yet-rendered campaign
    ///     may stay pending before the watchdog frees the slot. The watchdog is
    ///     the airbag, not the brakes: the explicit transitions are the
    ///     mechanism, and this only caps the blast radius of a future bug at one
    ///     campaign for a few seconds rather than a dead in-app channel for the
    ///     whole session.
    ///   - onDeliver: hands a trigger to Digia and returns its verdict.
    ///   - onInvalidate: asks Digia to tear down an experience it is still showing.
    ///   - onReleased: notified after the slot is freed, for diagnostics.
    init(
        acceptanceTimeout: TimeInterval = TemplateSlot.defaultAcceptanceTimeout,
        watchdogScheduler: WatchdogScheduling = TaskWatchdogScheduler(),
        onDeliver: @escaping (CEPTriggerPayload) -> Bool,
        onInvalidate: @escaping (String) -> Void,
        onReleased: @escaping (CampaignPresentation, PresentationOutcome) -> Void = { _, _ in }
    ) {
        self.acceptanceTimeout = acceptanceTimeout
        self.watchdogScheduler = watchdogScheduler
        self.onDeliver = onDeliver
        self.onInvalidate = onInvalidate
        self.onReleased = onReleased
    }

    /// Takes the slot for `trigger` and offers it to Digia.
    ///
    /// Total function: never throws, and always leaves the slot consistent. A
    /// rejection produces an already-settled presentation and an already-freed
    /// slot, so callers have one code path either way.
    @discardableResult
    func deliver(handle: TemplateHandle, trigger: CEPTriggerPayload) -> CampaignPresentation {
        // Defensive. CleverTap's one-visual-in-app rule should make an overlap
        // unreachable; if it happens anyway, freeing the incumbent beats wedging
        // the slot. Settling releases synchronously, so `active` is normally free
        // again by the next line.
        if let incumbent = active {
            Log.warn("template presented while \(incumbent.presentation.id) still holds the slot — superseding it")
            settle(incumbent.presentation, .dropped(reason: .superseded))
        }

        // Freeing the incumbent above can re-enter this method, because
        // dismissed() makes CleverTap pump the next queued in-app synchronously.
        // If that happened, the slot now belongs to that nested delivery and must
        // not be clobbered — hand this invocation straight back instead.
        if active != nil {
            Log.warn("slot was re-taken while superseding — declining '\(handle.templateName)'")
            return settledPresentation(
                trigger: trigger,
                outcome: .dropped(reason: .superseded, detail: "slot re-taken during release"),
                handle: handle
            )
        }

        deliveryCount += 1
        let presentation = CampaignPresentation(
            id: "ct-\(deliveryCount)",
            trigger: trigger,
            onCancel: { [weak self] cancelled in
                guard let self else { return }
                self.settle(cancelled, cancelled.terminalOutcome(drop: .cancelled, dismiss: .cancelled))
            }
        )
        let entry = Entry(presentation: presentation, handle: handle)
        active = entry
        entry.watchdog = watchdogScheduler.schedule(after: acceptanceTimeout) { [weak self] in
            guard let self, presentation.state == .pending else { return }
            Log.warn(
                "watchdog: \(presentation.id) (key=\(trigger.campaignKey)) was never rendered "
                    + "within \(self.acceptanceTimeout)s — freeing the in-app slot"
            )
            self.settle(
                presentation,
                .dropped(reason: .timeout, detail: "no Digia lifecycle event within \(self.acceptanceTimeout)s")
            )
        }

        // From here on this method must not touch `active`: settling releases
        // synchronously, which can re-enter deliver() through CleverTap's queue.
        guard onDeliver(trigger) else {
            Log.info("\(presentation.id) (key=\(trigger.campaignKey)) declined by Digia — freeing the in-app slot")
            settle(presentation, .dropped(reason: .rejectedByDigia))
            return presentation
        }
        return presentation
    }

    /// Builds an already-settled handle for a trigger that never took the slot,
    /// and frees `handle` if one was supplied.
    ///
    /// Callers that could not deliver still get a real ``CampaignPresentation``,
    /// so "rejected before we started" and "rejected by Digia" are the same shape
    /// to everything downstream.
    @discardableResult
    func settledPresentation(
        trigger: CEPTriggerPayload,
        outcome: PresentationOutcome,
        handle: TemplateHandle? = nil
    ) -> CampaignPresentation {
        deliveryCount += 1
        let presentation = CampaignPresentation(
            id: "ct-\(deliveryCount)",
            trigger: trigger,
            onCancel: { _ in }
        )
        presentation.settle(outcome)
        handle?.setDismissed()
        Log.info("\(presentation.id) settled as \(outcome) without taking the slot")
        onReleased(presentation, outcome)
        return presentation
    }

    /// Digia rendered the experience. Reports the impression to CleverTap, once.
    ///
    /// Deliberately deferred to this point rather than done when the presenter
    /// fired: `presented()` records the viewed event and consumes frequency
    /// budget, so calling it before Digia commits would book an impression for a
    /// campaign the user never saw (`clevertap.md` §9.3).
    func onDigiaImpressed(_ payload: CEPTriggerPayload) {
        guard let entry = entry(for: payload), entry.presentation.markDisplaying() else { return }
        entry.watchdog?.cancel()
        entry.watchdog = nil
        Log.info("\(entry.presentation.id) displayed — reporting the impression to CleverTap")
        entry.handle.setPresented()
    }

    /// Digia reported a click. Fires the campaign's primary action, if it
    /// declared one.
    func onDigiaClicked(_ payload: CEPTriggerPayload) {
        guard let entry = entry(for: payload) else { return }
        Log.info("\(entry.presentation.id) clicked — triggering '\(Self.primaryActionArgument)'")
        entry.handle.triggerAction(named: Self.primaryActionArgument)
    }

    /// Digia reported the experience closed. Terminal — frees the slot.
    func onDigiaDismissed(_ payload: CEPTriggerPayload) {
        guard let entry = entry(for: payload) else {
            Log.info(
                "dismiss for '\(payload.cepCampaignId)' does not hold the in-app slot "
                    + "(active=\(self.active?.presentation.trigger.cepCampaignId ?? "none")) — nothing to free"
            )
            return
        }
        settle(entry.presentation, entry.presentation.terminalOutcome(drop: .cancelled, dismiss: .digiaDismissed))
    }

    /// CleverTap asked the template to close — an in-app action used the close
    /// behaviour, or the campaign was pulled. Terminal on CleverTap's side too
    /// (`clevertap.md` §9.7).
    ///
    /// Digia is invalidated first so it can tear its UI down and emit its own
    /// terminal event, which settles the presentation through the normal path.
    /// The settle afterwards covers the case where Digia had nothing to dismiss
    /// and stayed silent; it is a no-op if the invalidation already settled it.
    func onCleverTapClose(_ handle: TemplateHandle) {
        guard let entry = active else {
            // A close for an invocation that never took the slot. It is still a
            // live CleverTap invocation, so it must reach a terminal state here
            // or it stalls the queue exactly as a forgotten dismiss would.
            Log.info("close for '\(handle.templateName)' with no campaign holding the slot")
            handle.setDismissed()
            return
        }
        Log.info("CleverTap closed '\(handle.templateName)' → invalidating \(entry.presentation.id)")
        onInvalidate(entry.presentation.trigger.cepCampaignId)
        settle(entry.presentation, entry.presentation.terminalOutcome(drop: .cancelled, dismiss: .cancelled))
    }

    /// Frees the slot because the plugin is going away.
    ///
    /// Digia core has no equivalent of the v2 spec's guarantee that a plugin's
    /// presentations are settled before it is detached, so the plugin settles its
    /// own here. Without this, unregistering or replacing the plugin mid-campaign
    /// strands CleverTap's slot with nothing left alive to free it.
    func teardown() {
        guard let entry = active else { return }
        Log.info("teardown while \(entry.presentation.id) holds the slot — freeing")
        settle(
            entry.presentation,
            entry.presentation.terminalOutcome(drop: .pluginDetached, dismiss: .pluginDetached)
        )
    }

    // MARK: - Internals

    /// The one place a presentation becomes terminal, and the only caller of
    /// ``release``. Losing a settlement race is a silent no-op, which is what
    /// makes every method above idempotent.
    private func settle(_ presentation: CampaignPresentation, _ outcome: PresentationOutcome) {
        guard presentation.settle(outcome) else { return }
        release(presentation, outcome)
    }

    /// Frees the slot. Ordered so it reads as free *before* CleverTap is told,
    /// because `dismissed()` synchronously pumps the next queued in-app, which
    /// can re-enter ``deliver(handle:trigger:)`` from inside this call.
    ///
    /// Idempotent: a presentation that no longer holds the slot returns early.
    private func release(_ presentation: CampaignPresentation, _ outcome: PresentationOutcome) {
        guard let entry = active, entry.presentation === presentation else { return }
        active = nil
        entry.watchdog?.cancel()
        entry.watchdog = nil

        entry.handle.setDismissed()
        Log.info("\(presentation.id) settled as \(outcome) → in-app slot freed")
        onReleased(presentation, outcome)
    }

    /// The entry this event belongs to, or `nil` to ignore it.
    ///
    /// Correlation is by `cepCampaignId` against the single slot holder. Digia
    /// core routes events by payload rather than by a presentation id, so this is
    /// the strongest correlation available; the single-slot invariant makes it
    /// sufficient. Native Display triggers never reach here — they take no slot.
    private func entry(for payload: CEPTriggerPayload) -> Entry? {
        guard let entry = active, entry.presentation.state != .settled else { return nil }
        return entry.presentation.trigger.cepCampaignId == payload.cepCampaignId ? entry : nil
    }
}
