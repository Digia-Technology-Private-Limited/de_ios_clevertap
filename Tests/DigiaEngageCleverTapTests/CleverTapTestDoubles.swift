@testable import DigiaEngage
@testable import DigiaEngageCleverTap
import Foundation

/// A CleverTap custom-template invocation, recording what the plugin did to it.
///
/// The counters matter more than they look: "dismissed exactly once" is the
/// property that keeps the customer's in-app channel alive, so the tests assert
/// counts rather than booleans throughout.
@MainActor
final class FakeTemplateHandle: TemplateHandle {
    let templateName: String
    private let arguments: [String: String?]

    private(set) var presentedCount = 0
    private(set) var dismissedCount = 0
    private(set) var triggeredActions: [String] = []

    /// Runs when CleverTap would pump the next queued in-app from inside dismiss.
    var onDismissed: (() -> Void)?

    init(
        templateName: String = CleverTapTemplates.templateName,
        campaignKey: String? = "onboarding_tip",
        variables: String? = nil
    ) {
        self.templateName = templateName
        self.arguments = [
            CleverTapTemplates.argCampaignKey: campaignKey,
            CleverTapTemplates.argVariables: variables,
        ]
    }

    var identity: AnyObject { self }

    func string(named name: String) -> String? { arguments[name] ?? nil }

    func setPresented() { presentedCount += 1 }

    func setDismissed() {
        dismissedCount += 1
        onDismissed?()
    }

    func triggerAction(named name: String) { triggeredActions.append(name) }
}

@MainActor
final class FakeCleverTapClient: CleverTapClient {
    private(set) var recordedScreens: [String] = []
    private(set) var viewedUnits: [String] = []
    private(set) var clickedUnits: [String] = []
    private(set) var syncCount = 0
    private(set) var listener: (@MainActor ([DisplayUnit]) -> Void)?

    var instanceAvailable = true
    private let cached: [DisplayUnit]

    init(cached: [DisplayUnit] = []) {
        self.cached = cached
    }

    /// Pushes a Display Unit batch the way CleverTap's delegate would.
    func emitDisplayUnits(_ units: [DisplayUnit]) { listener?(units) }

    func recordScreen(_ name: String) { recordedScreens.append(name) }
    func pushDisplayUnitViewed(_ unitId: String) { viewedUnits.append(unitId) }
    func pushDisplayUnitClicked(_ unitId: String) { clickedUnits.append(unitId) }
    func cachedDisplayUnits() -> [DisplayUnit] { cached }
    func setDisplayUnitListener(_ listener: (@MainActor ([DisplayUnit]) -> Void)?) { self.listener = listener }
    func syncRegisteredTemplates(isProduction: Bool) { syncCount += 1 }
    func hasInstance() -> Bool { instanceAvailable }
}

/// Stands in for Digia core.
///
/// Built on the real ``PresentationController``, so every guarantee the contract
/// enforces below that line — exactly-once settlement, no signals after the
/// outcome, `holdReleased` settling at or before `outcome` — holds in these tests
/// exactly as it will in production. The fake only decides *what* happens; it
/// cannot weaken *how*.
///
/// ``syncDrop`` is the single most important input here: it reproduces a
/// synchronous rejection (unknown key, frequency cap), and honouring it is what
/// keeps a declined campaign from stalling CleverTap's slot forever.
@MainActor
final class FakeCEPHost: DigiaCEPHost {
    /// When set, `deliver` returns an already-settled presentation.
    var syncDrop: DropReason?

    private(set) var delivered: [CEPTriggerPayload] = []
    private(set) var controllers: [PresentationController] = []
    private var nextId = 0

    init(syncDrop: DropReason? = nil) {
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
}

/// Lets main-actor continuations resumed by a settlement actually run.
///
/// A plugin binds its release to `await presentation.holdReleased.value`, so a
/// settlement made by the test resumes a task that runs on the *next* main-actor
/// turn, not inline. Synchronous drops and plugin-initiated terminations do not
/// need this — only settlements core makes on its own.
func drainMainActor(_ turns: Int = 5) async {
    for _ in 0..<turns { await Task.yield() }
}

@MainActor
func displayUnit(
    _ unitId: String,
    campaignKey: String,
    extra: [String: String] = [:]
) -> DisplayUnit {
    DisplayUnit(
        unitId: unitId,
        customKeyValues: ["digia_campaign_key": campaignKey].merging(extra) { _, new in new }
    )
}
