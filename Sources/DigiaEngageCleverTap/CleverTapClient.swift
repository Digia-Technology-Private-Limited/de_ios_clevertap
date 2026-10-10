import CleverTapSDK
import Foundation

/// One live CleverTap custom-template invocation.
///
/// Wraps `CTTemplateContext` so the slot state machine can be unit-tested without
/// a CleverTap instance. Every method here is synchronous in the real SDK, which
/// is why this plugin needs none of the promise-chain sequencing the React Native
/// plugin does.
@MainActor
protocol TemplateHandle: AnyObject {
    var templateName: String { get }

    /// The underlying SDK invocation.
    ///
    /// CleverTap hands the same context to `onPresent` and `onCloseClicked`, but
    /// each callback gets a fresh wrapper, so identity comparisons must go
    /// through this rather than through the wrapper itself.
    var identity: AnyObject { get }

    /// Reads a string argument declared on the template. `nil` if absent.
    func string(named name: String) -> String?

    /// Tells CleverTap the custom UI is now visible. Records the impression and
    /// updates frequency bookkeeping, so it must only be called once Digia has
    /// actually rendered — never optimistically.
    func setPresented()

    /// Marks this invocation terminal and releases CleverTap's global visual
    /// in-app slot.
    ///
    /// Safe to call without a preceding ``setPresented()``, so a dropped campaign
    /// frees the slot without recording a view it never got.
    ///
    /// May re-enter the presenter synchronously — CleverTap pumps the next queued
    /// in-app from inside this call.
    func setDismissed()

    /// Fires the template's `action` argument — the campaign author's primary
    /// click-through. A no-op (logged by the CleverTap SDK) when the campaign
    /// defined no action.
    func triggerAction(named name: String)
}

/// A CleverTap Native Display unit, flattened to the fields this plugin uses.
struct DisplayUnit: Sendable, Equatable {
    let unitId: String
    let customKeyValues: [String: String]
}

/// The CleverTap instance-level calls this plugin makes.
///
/// Kept behind a protocol so the plugin is testable without a CleverTap instance,
/// and so the one place that talks to the real SDK is obvious.
@MainActor
protocol CleverTapClient: AnyObject {
    func recordScreen(_ name: String)

    /// Native Display impression. CleverTap never infers this — the app owns it.
    func pushDisplayUnitViewed(_ unitId: String)

    /// Native Display click. CleverTap never infers this — the app owns it.
    func pushDisplayUnitClicked(_ unitId: String)

    /// Reads CleverTap's current Display Unit cache. Recovers units whose live
    /// callback fired before this plugin existed; not campaign history.
    func cachedDisplayUnits() -> [DisplayUnit]

    /// Installs the Display Unit delegate. CleverTap holds exactly one, so this
    /// replaces any delegate the host app set.
    func setDisplayUnitListener(_ listener: (@MainActor ([DisplayUnit]) -> Void)?)

    /// Pushes the locally registered template definitions to the CleverTap
    /// dashboard. Debug configurations only unless `isProduction` is set.
    func syncRegisteredTemplates(isProduction: Bool)

    /// Whether a CleverTap instance is actually reachable.
    func hasInstance() -> Bool
}

// MARK: - Real SDK implementations

/// ``TemplateHandle`` backed by a real CleverTap template context.
@MainActor
final class CleverTapTemplateHandle: TemplateHandle {
    let context: CTTemplateContext

    init(context: CTTemplateContext) {
        self.context = context
    }

    var templateName: String { context.name() }

    var identity: AnyObject { context }

    func string(named name: String) -> String? { context.string(name: name) }

    func setPresented() { context.presented() }

    func setDismissed() { context.dismissed() }

    func triggerAction(named name: String) { context.triggerAction(name: name) }
}

/// ``CleverTapClient`` backed by `CleverTap.sharedInstance()`.
///
/// The instance is resolved per call rather than captured: CleverTap's shared
/// instance can become available after this object is created, and holding a
/// stale `nil` would disable the plugin for the life of the process.
@MainActor
final class CleverTapSdkClient: CleverTapClient {

    /// Retained because CleverTap holds its Display Unit delegate weakly.
    private var displayUnitProxy: DisplayUnitProxy?

    func recordScreen(_ name: String) {
        CleverTap.sharedInstance()?.recordScreenView(name)
    }

    func pushDisplayUnitViewed(_ unitId: String) {
        CleverTap.sharedInstance()?.recordDisplayUnitViewedEvent(forID: unitId)
    }

    func pushDisplayUnitClicked(_ unitId: String) {
        CleverTap.sharedInstance()?.recordDisplayUnitClickedEvent(forID: unitId)
    }

    func cachedDisplayUnits() -> [DisplayUnit] {
        guard let units = CleverTap.sharedInstance()?.getAllDisplayUnits() else { return [] }
        return units.compactMap(Self.toDisplayUnit)
    }

    func setDisplayUnitListener(_ listener: (@MainActor ([DisplayUnit]) -> Void)?) {
        guard let listener else {
            // CleverTap's setDisplayUnitDelegate takes a nonnull delegate, so the
            // delegate cannot be uninstalled. Dropping our proxy is the closest
            // available equivalent: CleverTap's weak reference goes nil and
            // stops delivering. See ai_docs/cep-clevertap-plugin-v2.md.
            displayUnitProxy = nil
            return
        }
        let proxy = DisplayUnitProxy(onUnits: listener)
        displayUnitProxy = proxy
        CleverTap.sharedInstance()?.setDisplayUnitDelegate(proxy)
    }

    func syncRegisteredTemplates(isProduction: Bool) {
        guard let instance = CleverTap.sharedInstance() else { return }
        if isProduction {
            instance.syncCustomTemplates(true)
        } else {
            instance.syncCustomTemplates()
        }
    }

    func hasInstance() -> Bool { CleverTap.sharedInstance() != nil }

    /// `nonisolated` so the Display Unit delegate can normalise off the main
    /// thread: `CleverTapDisplayUnit` is not `Sendable`, so it must be reduced to
    /// plain values *before* hopping to the main actor, not after.
    nonisolated static func toDisplayUnit(_ unit: CleverTapDisplayUnit) -> DisplayUnit? {
        guard let unitId = unit.unitID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !unitId.isEmpty
        else { return nil }

        var keyValues: [String: String] = [:]
        for (key, value) in unit.customExtras ?? [:] {
            guard let key = key as? String, let stringValue = stringify(value) else { continue }
            keyValues[key] = stringValue
        }
        return DisplayUnit(unitId: unitId, customKeyValues: keyValues)
    }

    /// `customExtras` is an untyped dictionary, unlike Android's `HashMap<String, String>`,
    /// so scalars are normalised here rather than in the mapper.
    nonisolated private static func stringify(_ value: Any) -> String? {
        switch value {
        case let string as String: return string.isEmpty ? nil : string
        // `NSNumber.stringValue` renders a JSON `true` as "1", so `{{ on_sale }}` read "1"
        // here and "true" on Android and Flutter. A boolean interpolates as a boolean.
        case let number as NSNumber:
            return CFGetTypeID(number) == CFBooleanGetTypeID()
                ? String(number.boolValue) : number.stringValue
        default: return nil
        }
    }
}

/// Adapts CleverTap's Objective-C delegate to a closure.
private final class DisplayUnitProxy: NSObject, CleverTapDisplayUnitDelegate {
    private let onUnits: @MainActor ([DisplayUnit]) -> Void

    init(onUnits: @escaping @MainActor ([DisplayUnit]) -> Void) {
        self.onUnits = onUnits
    }

    func displayUnitsUpdated(_ displayUnits: [CleverTapDisplayUnit]) {
        // Normalise here, on whatever thread CleverTap used: the SDK's unit type
        // is not Sendable, so only the flattened values may cross to the main actor.
        let mapped = displayUnits.compactMap(CleverTapSdkClient.toDisplayUnit)
        guard !mapped.isEmpty else { return }
        onMainActor { [onUnits] in onUnits(mapped) }
    }
}
