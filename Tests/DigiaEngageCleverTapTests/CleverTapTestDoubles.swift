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

/// A manual clock and timer for the pending buffer: `advance` fires due timers.
@MainActor
final class FakeClock {
    var now = Date(timeIntervalSince1970: 0)
    private var timers: [(id: Int, due: Date, work: @MainActor () -> Void)] = []
    private var nextId = 0

    func schedule(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> () -> Void {
        nextId += 1
        let id = nextId
        timers.append((id, now.addingTimeInterval(delay), work))
        return { [weak self] in self?.timers.removeAll { $0.id == id } }
    }

    func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
        while let index = timers.firstIndex(where: { $0.due <= now }) {
            timers.remove(at: index).work()
        }
    }
}
