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
    func recordScreen(_ name: String)
    func dismissTemplate(_ templateName: String)
    func getDisplayUnits() -> [[String: Any]]
    func isAvailable() -> Bool
    func hasDefaultInstance() -> Bool
}

final class CleverTapSdkBridge: CleverTapBridge {
    private var inAppProxy: CleverTapInAppRuntimeProxy?
    private var displayUnitProxy: CleverTapDisplayUnitRuntimeProxy?
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
        let displayUnitProxy = CleverTapDisplayUnitRuntimeProxy(onPayload: onPayload)

        instance.setInAppNotificationDelegate(inAppProxy)
        instance.setDisplayUnitDelegate(displayUnitProxy)

        self.inAppProxy = inAppProxy
        self.displayUnitProxy = displayUnitProxy
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
        listenersRegistered = false
        inAppProxy = nil
        displayUnitProxy = nil
    }

    func getDisplayUnits() -> [[String: Any]] {
        guard let units = CleverTap.sharedInstance()?.getAllDisplayUnits() else { return [] }
        return units.compactMap { normalizeDisplayUnit($0) }
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

private func normalizeDisplayUnit(_ unit: Any) -> [String: Any]? {
    let object = unit as AnyObject
    let unitID = object.value(forKey: "unitID") as? String
        ?? object.value(forKey: "wzrk_id") as? String
    let extras = object.value(forKey: "customExtras") as? [AnyHashable: Any]
    var normalized: [String: Any] = [:]
    if let unitID, !unitID.isEmpty { normalized["id"] = unitID }
    for (key, value) in extras ?? [:] {
        guard let key = key as? String else { continue }
        normalized[key] = value
    }
    return normalized.isEmpty ? nil : normalized
}

private final class CleverTapDisplayUnitRuntimeProxy: NSObject, CleverTapDisplayUnitDelegate {
    private let onPayload: ([String: Any]) -> Void

    init(onPayload: @escaping ([String: Any]) -> Void) {
        self.onPayload = onPayload
    }

    @objc func displayUnitsUpdated(_ displayUnits: [Any]!) {
        for unit in displayUnits ?? [] {
            if let normalized = normalizeDisplayUnit(unit) {
                onPayload(normalized)
            }
        }
    }
}
