import CleverTapSDK
import Foundation

/// Receives live CleverTap custom-template invocations. Implemented by the plugin.
@MainActor
protocol TemplateSink: AnyObject {
    /// A `DigiaTemplate` invocation reached the head of CleverTap's in-app queue.
    func onTemplatePresented(_ handle: TemplateHandle)

    /// CleverTap asked a `DigiaTemplate` invocation to close.
    func onTemplateClosed(_ handle: TemplateHandle)
}

/// Process-global registration of Digia's CleverTap custom templates.
///
/// ## Why this is a global and not plugin state
///
/// CleverTap requires custom templates to be registered **before** the CleverTap
/// instance is created (`docs-internal/cep-integrations/clevertap.md` §9.1), and
/// `CleverTap.registerCustom(inAppTemplates:)` is a static, once-per-process
/// call. That is strictly earlier than `Digia.register(plugin)` can run, so
/// registration cannot live on the plugin instance. The presenters below
/// therefore outlive any particular plugin and forward to whichever one is
/// currently attached.
///
/// ## The definition
///
/// ```text
/// DigiaTemplate (visual template)
///   digia_campaign_key : string  — couples this CleverTap campaign to a Digia one
///   variables          : string  — JSON blob interpolated into the Digia config
///   action             : action  — the campaign author's primary click-through
///
/// DigiaPrimaryClick (non-visual function)
///   (no arguments)
/// ```
///
/// This must match what is uploaded to the CleverTap dashboard. It is
/// deliberately identical to the Android plugin's definition and to the one the
/// React Native plugin ships as `digia.json`, so one dashboard template works
/// against every Digia stack.
///
/// `DigiaPrimaryClick` exists so a campaign author can attach "just record the
/// click" to the `action` argument. Being non-visual it never takes the visual
/// slot, but it is still a custom-template invocation and must be completed, or
/// it leaks CleverTap-side state.
///
/// ## Testability
///
/// This type is the deliberately logic-free adapter over CleverTap's statics —
/// the one sliver of the plugin that unit tests cannot reach. Everything that
/// *decides* anything lives in ``TemplateSlot`` and ``CleverTapPayloadMapper``,
/// which are covered directly.
@MainActor
enum CleverTapTemplates {

    // `nonisolated`: these are immutable names read by CleverTap's ObjC
    // producer callback, which runs outside the main actor.
    nonisolated static let templateName = "DigiaTemplate"
    nonisolated static let primaryClickFunction = "DigiaPrimaryClick"

    nonisolated static let argCampaignKey = "digia_campaign_key"
    nonisolated static let argVariables = "variables"

    /// How long a template invocation may sit buffered waiting for
    /// `Digia.register()` before the slot is handed back.
    ///
    /// Buffering at all is what lets an app-launch campaign survive the gap
    /// between CleverTap firing and Digia being registered. Bounding it is what
    /// stops that same gap from stalling the customer's entire in-app channel
    /// when registration never happens — a misconfigured app would otherwise hold
    /// the slot for the whole session.
    nonisolated static let attachGrace: TimeInterval = 10

    private static var isRegistered = false
    private static weak var sink: TemplateSink?

    /// A template invocation that arrived before any plugin was attached, with
    /// the task that will release it if none ever attaches.
    private static var buffered: (handle: TemplateHandle, timeout: Task<Void, Never>)?

    /// Registers `DigiaTemplate` and `DigiaPrimaryClick` with CleverTap.
    ///
    /// Idempotent, and must be called before CleverTap initialises — in practice
    /// from `application(_:didFinishLaunchingWithOptions:)`, via
    /// ``DigiaCleverTapPlugin/prepareCleverTapCustomTemplates()``. Calling it
    /// later still succeeds but CleverTap will have already filtered out any
    /// campaign that targeted the template in the meantime.
    static func register() {
        guard !isRegistered else { return }
        isRegistered = true
        CleverTap.registerCustom(inAppTemplates: DigiaTemplateProducer())
    }

    /// Attaches `newSink` and flushes any invocation buffered while nothing was
    /// attached. Replaces a previous sink; the plugin being replaced is
    /// responsible for freeing anything it still holds.
    static func attach(_ newSink: TemplateSink) {
        sink = newSink
        guard let pending = buffered else { return }
        buffered = nil
        pending.timeout.cancel()
        Log.info("flushing a template invocation buffered before attach")
        newSink.onTemplatePresented(pending.handle)
    }

    /// Detaches `oldSink` if it is still the current one.
    ///
    /// Scoped to the caller so a plugin that was already replaced cannot detach
    /// its successor — the replace-then-teardown ordering in Digia's plugin
    /// registry makes that sequence reachable.
    static func detach(_ oldSink: TemplateSink) {
        if sink === oldSink { sink = nil }
    }

    /// Routes a live invocation to the attached sink, or buffers it under a
    /// bounded grace period. Always ends with the invocation owned by someone.
    private static func dispatchPresented(_ handle: TemplateHandle) {
        if let sink {
            sink.onTemplatePresented(handle)
            return
        }

        if let displaced = buffered {
            // Only one invocation can be buffered; CleverTap's single visual slot
            // makes a second one unreachable in practice, but a stranded handle
            // would stall the queue, so free it rather than drop the reference.
            buffered = nil
            displaced.timeout.cancel()
            Log.warn("a second template invocation arrived while buffered — freeing the first")
            displaced.handle.setDismissed()
        }

        Log.info("no plugin attached yet — buffering '\(handle.templateName)'")
        let timeout = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(attachGrace * 1_000_000_000))
            guard !Task.isCancelled, let pending = buffered,
                  pending.handle.identity === handle.identity else { return }
            buffered = nil
            Log.warn(
                "no Digia plugin registered within \(attachGrace)s of '\(handle.templateName)' "
                    + "presenting — freeing the in-app slot. Call Digia.register(DigiaCleverTapPlugin()) during startup."
            )
            handle.setDismissed()
        }
        buffered = (handle, timeout)
    }

    private static func dispatchClosed(_ handle: TemplateHandle) {
        if let sink {
            sink.onTemplateClosed(handle)
            return
        }
        if let pending = buffered, pending.handle.identity === handle.identity {
            buffered = nil
            pending.timeout.cancel()
        }
        // Terminal either way — an unowned close must still free the slot.
        handle.setDismissed()
    }

    // MARK: - CleverTap adapters

    private final class DigiaTemplateProducer: NSObject, CTTemplateProducer {
        func defineTemplates(_: CleverTapInstanceConfig) -> Set<CTCustomTemplate> {
            let template = CTInAppTemplateBuilder()
            template.setName(CleverTapTemplates.templateName)
            template.addArgument(CleverTapTemplates.argCampaignKey, string: "")
            template.addArgument(CleverTapTemplates.argVariables, string: "{}")
            template.addActionArgument(TemplateSlot.primaryActionArgument)
            template.setPresenter(DigiaTemplatePresenter())

            let function = CTAppFunctionBuilder(isVisual: false)
            function.setName(CleverTapTemplates.primaryClickFunction)
            function.setPresenter(DigiaPrimaryClickPresenter())

            return [template.build(), function.build()]
        }
    }

    private final class DigiaTemplatePresenter: NSObject, CTTemplatePresenter {
        func onPresent(context: CTTemplateContext) {
            // CTTemplateContext is a non-Sendable ObjC type. CleverTap invokes
            // presenters on the main thread, and past this point the context is
            // only ever touched on the main actor, so handing it across is safe.
            nonisolated(unsafe) let context = context
            onMainActor {
                CleverTapTemplates.dispatchPresented(CleverTapTemplateHandle(context: context))
            }
        }

        func onCloseClicked(context: CTTemplateContext) {
            nonisolated(unsafe) let context = context
            onMainActor {
                CleverTapTemplates.dispatchClosed(CleverTapTemplateHandle(context: context))
            }
        }
    }

    /// Completes a `DigiaPrimaryClick` invocation.
    ///
    /// Non-visual, so there is nothing to show and nothing to ask Digia about —
    /// the click has already been recorded by CleverTap by the time the function
    /// runs. All that is owed is the terminal call.
    private final class DigiaPrimaryClickPresenter: NSObject, CTTemplatePresenter {
        func onPresent(context: CTTemplateContext) {
            nonisolated(unsafe) let context = context
            onMainActor {
                Log.info("completing \(CleverTapTemplates.primaryClickFunction)")
                context.dismissed()
            }
        }

        func onCloseClicked(context: CTTemplateContext) {
            nonisolated(unsafe) let context = context
            onMainActor { context.dismissed() }
        }
    }
}
