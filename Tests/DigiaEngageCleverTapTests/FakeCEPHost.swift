@testable import DigiaEngage
import Foundation

// The shared CEP conformance harness.
//
// This file is **character-identical in ios/clevertap, ios/webengage and
// ios/moengage**. The three plugins are separate Git repositories with no
// shared test artifact and no pod either of them could depend on, so one copy
// per repo is the only way to have one shape. Treat it as a single file that
// happens to live in three places: change it in one repo and change it in all
// three, in the same change set, character for character.
//
// It is deliberately built on the **real** ``PresentationController`` rather
// than a hand-rolled stand-in. Every guarantee the contract enforces below that
// line therefore holds in these suites exactly as it will in production — G1
// exactly-once settlement, G3 `displayed` at most once and first, G4 no signals
// after the outcome, G5 idempotent `cancel()`, G8 `holdReleased` at or before
// `outcome` — and a regression in the contract breaks the plugin suites instead
// of passing silently. A fake host may decide *what* happens; it cannot weaken
// *how*.

/// Stands in for Digia core: scriptable outcomes and signal injection.
@MainActor
final class FakeCEPHost: DigiaCEPHost {

    /// When set, ``deliver(_:)`` returns an already-settled presentation.
    ///
    /// The single most important input here. It reproduces a synchronous
    /// rejection — unknown key, frequency cap — whose hold is released before
    /// any awaiting task could possibly exist, and honouring it is what keeps a
    /// declined campaign from stalling the CEP for the rest of the session.
    /// That is the original F1 bug.
    var syncDrop: DropReason?

    /// What ``isReady`` reports. Default `true`, so a suite that does not care
    /// about the pending buffer delivers straight through.
    var isReady = true

    private(set) var delivered: [CEPTriggerPayload] = []
    private(set) var controllers: [PresentationController] = []
    private var nextId = 0

    /// `nonisolated`: the plugin suites use a `FakeCEPHost` as a default
    /// argument, which Swift evaluates outside the main actor.
    nonisolated init(syncDrop: DropReason? = nil) {
        self.syncDrop = syncDrop
    }

    func deliver(_ trigger: CEPTriggerPayload) -> CampaignPresentation {
        delivered.append(trigger)
        nextId += 1
        let controller = PresentationController(id: "p-\(nextId)", trigger: trigger)
        controllers.append(controller)
        if let syncDrop {
            controller.settle(.dropped(reason: syncDrop, detail: nil))
        }
        return controller.presentation
    }

    /// The controller for the most recent delivery — the test's handle on core.
    var last: PresentationController { controllers[controllers.count - 1] }

    /// What core does on `unregister()` under G6: settle every presentation the
    /// plugin owns with `plugin_detached`, **before** `detach()` runs.
    ///
    /// Neither native core implements G6 until N4, so this fake is standing in
    /// for it. Driving scenario C4 through here — and not through `detach()`
    /// alone — is what makes that scenario assert the *fact* (the CEP's hold is
    /// gone, exactly once) instead of a code path, so it stays true whether a
    /// plugin keeps its own detach backstop or relies purely on G6.
    func settleOwnedPresentations() {
        for controller in controllers where !controller.isSettled {
            controller.settle(
                controller.state == .displaying
                    ? .dismissed(reason: .pluginDetached, completed: false)
                    : .dropped(reason: .pluginDetached, detail: nil)
            )
        }
    }
}

/// Lets main-actor continuations resumed by a settlement actually run.
///
/// A plugin binds its terminal work to `await presentation.outcome.value` or
/// `await presentation.holdReleased.value`, so a settlement made by a test
/// resumes a task that runs on the *next* main-actor turn, not inline.
/// Synchronous drops and plugin-initiated terminations do not need this — only
/// settlements core makes on its own.
func drainMainActor(_ turns: Int = 5) async {
    for _ in 0..<turns { await Task.yield() }
}

/// Whether an awaiter attached **after** a promise settled still fires.
///
/// This is scenario C8's real assertion, and the only thing that would catch
/// ``PresentationPromise`` regressing into a fire-and-forget signal: each
/// plugin's own synchronous-drop path peeks at `isSettled` first, so it would
/// keep releasing even then, and every other scenario would stay green.
///
/// Nothing here can hang the suite. A promise that never settles simply leaves
/// the flag false and fails the expectation.
@MainActor
func awaiterAttachedLateFires(_ promise: PresentationPromise<Void>) async -> Bool {
    let flag = LateAwaiterFlag()
    Task { @MainActor in
        await promise.value
        flag.fired = true
    }
    await drainMainActor()
    return flag.fired
}

@MainActor
private final class LateAwaiterFlag {
    var fired = false
}
