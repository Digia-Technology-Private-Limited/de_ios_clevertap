import DigiaEngage
import Foundation

/// Why a presentation ended without ever being displayed.
///
/// Mirrors `DropReason` in the Core ↔ CEP Interface v2 spec, and the Kotlin
/// plugin's enum of the same name. Only the arms this plugin can actually
/// observe are modelled — a reason it has no way to distinguish would be a lie in
/// the logs. Digia core answers `onCampaignTriggered` with a bare `Bool`, so
/// every core-side rejection collapses into ``rejectedByDigia``. What a future
/// core would have to return to split them apart is recorded in de_workspace
/// `ai_docs/cep-clevertap-plugin-v2.md`.
public enum DropReason: String, Sendable {
    /// The template carried no usable `digia_campaign_key`.
    case missingCampaignKey

    /// No Digia delegate was attached when the template reached the presenter.
    case notAttached

    /// Digia declined the campaign. Covers unknown campaign key, SDK not ready,
    /// and native frequency capping — core returns one `false` for all of them.
    case rejectedByDigia

    /// CleverTap asked the template to close before Digia rendered anything.
    case cancelled

    /// CleverTap handed us a second template while this one still held the slot.
    /// Defensive only — CleverTap's single-visual-in-app rule should make it
    /// unreachable — but releasing the incumbent beats wedging the slot forever.
    case superseded

    /// The plugin was torn down while this presentation was still pending.
    case pluginDetached

    /// Watchdog: Digia never reported a lifecycle event in time.
    case timeout

    /// An exception escaped the delivery path. Specifics land in `detail`.
    case error
}

/// How a presentation that did reach the screen ended.
public enum DismissReason: String, Sendable {
    /// Digia reported the experience dismissed.
    case digiaDismissed

    /// CleverTap asked the template to close while it was on screen.
    case cancelled

    /// The plugin was torn down while the experience was on screen.
    case pluginDetached
}

/// Exactly-once terminal result of a presentation. Two arms and only two: it was
/// displayed and has now closed, or it never displayed.
///
/// In **both** arms CleverTap's in-app slot must be released. That is exactly why
/// releasing is bound to *settling* rather than to either arm — see
/// ``TemplateSlot``, whose single settle funnel is the only path to both.
///
/// `detail` is debug-only free text (which exception, which argument): log it,
/// never branch on it.
public enum PresentationOutcome: Sendable, Equatable {
    case dismissed(reason: DismissReason)
    case dropped(reason: DropReason, detail: String? = nil)
}

/// Lifecycle position of a ``CampaignPresentation``.
public enum PresentationState: Sendable {
    case pending
    case displaying
    case settled
}

/// A claim ticket for one trigger delivered into Digia, owned exclusively by the
/// plugin that created it.
///
/// This is the plugin-local form of the spec's `CampaignPresentation`. It exists
/// because CleverTap's in-app slot is a *resource* with an acquire and a release,
/// and the only safe way to model a resource is an object whose termination is
/// guaranteed — not a boolean plus nine call sites that each have to remember.
///
/// ## The guarantee
///
/// ``outcome`` is set **exactly once**, always:
///
/// - exactly once, because ``settle(_:)`` refuses a second write and reports
///   which caller won;
/// - always, because ``TemplateSlot`` arms a watchdog at delivery time that
///   settles anything still ``PresentationState/pending`` when it fires.
///
/// ``TemplateSlot`` frees the CleverTap slot in the same step that settles this,
/// so no path — drop, close, teardown, error, timeout — can reach a terminal
/// state while still holding the slot.
///
/// ## Parity note
///
/// The Kotlin plugin exposes `outcome` as a `Deferred`, since `CompletableDeferred`
/// is Kotlin's natural exactly-once primitive. Swift has no direct equivalent that
/// is worth the machinery here, so this is a set-once property instead. The
/// observable contract — one terminal value, never overwritten — is identical.
@MainActor
public final class CampaignPresentation {

    /// Plugin-generated and unique per delivery. Deliberately *not*
    /// `CEPTriggerPayload.cepCampaignId`: on the custom-template path that field
    /// is the campaign key itself, so re-triggering one campaign would collide in
    /// every bookkeeping map. This id is the correlation key for logs.
    public let id: String

    /// The trigger exactly as handed to Digia.
    public let trigger: CEPTriggerPayload

    public private(set) var state: PresentationState = .pending

    /// The terminal result, or `nil` while still live. Set exactly once.
    public private(set) var outcome: PresentationOutcome?

    /// Invoked by ``cancel()``. Set by the owning ``TemplateSlot``.
    private let onCancel: (CampaignPresentation) -> Void

    init(id: String, trigger: CEPTriggerPayload, onCancel: @escaping (CampaignPresentation) -> Void) {
        self.id = id
        self.trigger = trigger
        self.onCancel = onCancel
    }

    /// Owner-initiated termination — CleverTap closed the template, or the plugin
    /// is being torn down. Idempotent, and a no-op once settled.
    public func cancel() {
        guard state != .settled else { return }
        onCancel(self)
    }

    // MARK: - Transitions. Only TemplateSlot may drive these.

    /// Marks the experience as on screen. Returns `true` only for the first call
    /// on a live presentation, so the caller can do the once-only work
    /// (`presented()`) without tracking a separate flag.
    @discardableResult
    func markDisplaying() -> Bool {
        guard state == .pending else { return false }
        state = .displaying
        return true
    }

    /// Records the terminal result. Returns `true` if this call was the one that
    /// settled it; a loser must not touch state.
    @discardableResult
    func settle(_ result: PresentationOutcome) -> Bool {
        guard outcome == nil else { return false }
        outcome = result
        state = .settled
        return true
    }

    /// Picks the outcome arm that matches where the presentation actually got to:
    /// one that never displayed is a drop, one that did is a dismissal. Used by
    /// the paths that are terminal regardless of progress — CleverTap close and
    /// plugin teardown.
    func terminalOutcome(drop: DropReason, dismiss: DismissReason) -> PresentationOutcome {
        state == .displaying ? .dismissed(reason: dismiss) : .dropped(reason: drop)
    }
}
