import Foundation
import CleverTapSDK
import UIKit

protocol CleverTapBridge: AnyObject {
    func registerTemplateCallbacks(
        onPayload: @escaping ([String: Any]) -> Void,
        onInvalidate: @escaping (String) -> Void
    )
    func unregisterTemplateCallbacks()
    func registerInAppListener(
        onPayload: @escaping ([String: Any]) -> Void,
        onInvalidate: @escaping (String) -> Void
    )
    func unregisterInAppListener()
    /// Re-dispatches display units CleverTap has already cached natively.
    ///
    /// CleverTap delivers Native Display units once, via the display-unit
    /// delegate. If a unit was loaded (and its delegate callback fired) on app
    /// launch *before* `setup()` attached our delegate, that live event is lost
    /// — the emitter does not buffer it. Replaying the native cache on register
    /// recovers those otherwise-missed launch campaigns. Deduped by unit id so a
    /// unit seen both live and via replay triggers only once.
    func replayCachedDisplayUnits()
    func recordScreen(_ name: String)
    func dismissTemplate(_ templateName: String)
    func isAvailable() -> Bool
    func hasDefaultInstance() -> Bool
}

final class CleverTapSdkBridge: CleverTapBridge {
    private var inAppProxy: CleverTapInAppRuntimeProxy?
    private var displayUnitProxy: CleverTapDisplayUnitRuntimeProxy?
    private var displayUnitPayload: (([String: Any]) -> Void)?
    private var dispatchedUnitIDs = Set<String>()
    private var listenersRegistered = false
    private var templateCallbacksRegistered = false
    private var appActiveObserver: NSObjectProtocol?

    func registerTemplateCallbacks(
        onPayload: @escaping ([String: Any]) -> Void,
        onInvalidate: @escaping (String) -> Void
    ) {
        CleverTapTemplateRegistration.register()
        CleverTapTemplateRegistration.setCallbacks(
            onPayload: onPayload,
            onInvalidated: onInvalidate
        )
        templateCallbacksRegistered = true
    }

    func unregisterTemplateCallbacks() {
        CleverTapTemplateRegistration.clearCallbacks()
        templateCallbacksRegistered = false
    }

    func registerInAppListener(
        onPayload: @escaping ([String: Any]) -> Void,
        onInvalidate: @escaping (String) -> Void
    ) {
        guard let instance = CleverTap.sharedInstance() else {
            listenersRegistered = false
            return
        }

        let inAppProxy = CleverTapInAppRuntimeProxy(onPayload: onPayload, onInvalidate: onInvalidate)
        let displayUnitProxy = CleverTapDisplayUnitRuntimeProxy { [weak self] units in
            self?.dispatchDisplayUnits(units)
        }

        instance.setInAppNotificationDelegate(inAppProxy)
        instance.setDisplayUnitDelegate(displayUnitProxy)

        self.inAppProxy = inAppProxy
        self.displayUnitProxy = displayUnitProxy
        self.displayUnitPayload = onPayload
        listenersRegistered = true

        appActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            CleverTap.sharedInstance()?.resumeInAppNotifications()
        }

        DispatchQueue.main.async {
            CleverTap.sharedInstance()?.resumeInAppNotifications()
        }
    }

    func unregisterInAppListener() {
        if let observer = appActiveObserver {
            NotificationCenter.default.removeObserver(observer)
            appActiveObserver = nil
        }
        guard let instance = CleverTap.sharedInstance() else {
            listenersRegistered = false
            inAppProxy = nil
            displayUnitProxy = nil
            displayUnitPayload = nil
            dispatchedUnitIDs.removeAll()
            return
        }

        listenersRegistered = false
        inAppProxy = nil
        displayUnitProxy = nil
        displayUnitPayload = nil
        dispatchedUnitIDs.removeAll()
    }

    func replayCachedDisplayUnits() {
        guard let units = CleverTap.sharedInstance()?.getAllDisplayUnits() else { return }
        dispatchDisplayUnits(units)
    }

    /// Normalizes, dedupes (by unit id) and forwards a batch of display units.
    /// Shared by the live `displayUnitsUpdated` delegate callback and the
    /// `replayCachedDisplayUnits()` launch-race recovery so a unit delivered via
    /// both paths is only dispatched once.
    private func dispatchDisplayUnits(_ displayUnits: [Any]) {
        guard let onPayload = displayUnitPayload else { return }
        for unit in displayUnits {
            let object = unit as AnyObject
            let unitID = object.value(forKey: "unitID") as? String
                ?? object.value(forKey: "wzrk_id") as? String
            if let unitID, !unitID.isEmpty, !dispatchedUnitIDs.insert(unitID).inserted {
                continue
            }
            let extras = object.value(forKey: "customExtras") as? [AnyHashable: Any]
            var normalized: [String: Any] = [:]
            if let unitID, !unitID.isEmpty { normalized["id"] = unitID }
            for (key, value) in extras ?? [:] {
                guard let key = key as? String else { continue }
                normalized[key] = value
            }
            if !normalized.isEmpty { onPayload(normalized) }
        }
    }

    func recordScreen(_ name: String) {
        CleverTap.sharedInstance()?.recordScreenView(name)
    }

    func dismissTemplate(_ templateName: String) {
        CleverTapTemplateRegistration.dismissTemplate(named: templateName)
    }

    func isAvailable() -> Bool {
        listenersRegistered && templateCallbacksRegistered
    }

    func hasDefaultInstance() -> Bool {
        CleverTap.sharedInstance() != nil
    }
}

private final class CleverTapInAppRuntimeProxy: NSObject, CleverTapInAppNotificationDelegate {
    private let onPayload: ([String: Any]) -> Void
    private let onInvalidate: (String) -> Void

    init(
        onPayload: @escaping ([String: Any]) -> Void,
        onInvalidate: @escaping (String) -> Void
    ) {
        self.onPayload = onPayload
        self.onInvalidate = onInvalidate
    }

    @objc func shouldShowInAppNotification(withExtras extras: [AnyHashable: Any]!) -> Bool {
        let normalized = normalize(extras)
        if !normalized.isEmpty { onPayload(normalized) }
        return true
    }

    @objc func inAppNotificationDismissed(withExtras extras: [AnyHashable: Any]!, andActionExtras actionExtras: [AnyHashable: Any]!) {
        let normalized = normalize(extras)
        if let payloadId = normalized["wzrk_id"] as? String
            ?? normalized["id"] as? String
            ?? normalized["msg_id"] as? String {
            onInvalidate(payloadId)
        }
    }

    private func normalize(_ dictionary: [AnyHashable: Any]?) -> [String: Any] {
        guard let dictionary else { return [:] }
        var result: [String: Any] = [:]
        for (key, value) in dictionary {
            guard let key = key as? String else { continue }
            result[key] = value
        }
        return result
    }
}

private final class CleverTapDisplayUnitRuntimeProxy: NSObject, CleverTapDisplayUnitDelegate {
    private let onUnits: ([Any]) -> Void

    init(onUnits: @escaping ([Any]) -> Void) {
        self.onUnits = onUnits
    }

    @objc func displayUnitsUpdated(_ displayUnits: [Any]!) {
        onUnits(displayUnits ?? [])
    }
}
