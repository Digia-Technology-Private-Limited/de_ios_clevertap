import Foundation
import CleverTapSDK

enum CleverTapTemplateRegistration {
    static let templateName = "DigiaTemplate"

    nonisolated(unsafe) private static var isRegistered = false
    nonisolated(unsafe) private static var onPayload: (([String: Any]) -> Void)?
    nonisolated(unsafe) private static var onInvalidated: ((String) -> Void)?
    nonisolated(unsafe) private static var activeContext: CTTemplateContext?

    /// Payload buffered when onPresent fires before setCallbacks is called.
    /// Accessed only on the main queue (activate dispatches to main).
    nonisolated(unsafe) private static var pendingPayload: [String: Any]?

    static func register() {
        guard !isRegistered else { return }
        CleverTap.registerCustom(inAppTemplates: DigiaTemplateProducer())
        isRegistered = true
    }

    static func setCallbacks(
        onPayload: @escaping ([String: Any]) -> Void,
        onInvalidated: @escaping (String) -> Void
    ) {
        self.onPayload = onPayload
        self.onInvalidated = onInvalidated
        if let pending = pendingPayload {
            pendingPayload = nil
            onPayload(pending)
        }
    }

    static func clearCallbacks() {
        onPayload = nil
        onInvalidated = nil
        pendingPayload = nil
    }

    static func activate(context: CTTemplateContext, campaignKey: String, rawVariables: String?) {
        activeContext = context
        context.presented()
        var payload: [String: Any] = [
            "id": campaignKey,
            "digia_campaign_key": campaignKey,
            "templateName": templateName,
        ]
        if let rawVars = rawVariables, !rawVars.isEmpty, rawVars != "{}" {
            payload["$variables"] = rawVars
        }
        // Dispatch to main so both the buffer write and setCallbacks run on the
        // same queue, preventing a read/write race.
        DispatchQueue.main.async {
            if let cb = Self.onPayload {
                cb(payload)
            } else {
                Self.pendingPayload = payload
            }
        }
    }

    static func dismissTemplate(named templateName: String) {
        guard templateName == Self.templateName, let context = activeContext else { return }
        activeContext = nil
        context.dismissed()
    }

    static func invalidate(context: CTTemplateContext, campaignKey: String) {
        if activeContext?.name() == context.name() {
            activeContext = nil
        }
        context.dismissed()
        onInvalidated?(campaignKey)
    }
}

private final class DigiaTemplateProducer: NSObject, CTTemplateProducer {
    func defineTemplates(_: CleverTapInstanceConfig!) -> Set<CTCustomTemplate>! {
        let builder = CTInAppTemplateBuilder()
        builder.setName(CleverTapTemplateRegistration.templateName)
        builder.addArgument("digia_campaign_key", string: "")
        builder.addArgument("variables", string: "{}")
        builder.setPresenter(DigiaTemplatePresenter())
        return [builder.build()]
    }
}

private final class DigiaTemplatePresenter: NSObject, CTTemplatePresenter {
    func onPresent(context: CTTemplateContext) {
        let campaignKey = context.string(name: "digia_campaign_key")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !campaignKey.isEmpty else {
            context.dismissed()
            return
        }
        let rawVariables = context.string(name: "variables")?.trimmingCharacters(in: .whitespacesAndNewlines)
        CleverTapTemplateRegistration.activate(
            context: context,
            campaignKey: campaignKey,
            rawVariables: rawVariables
        )
    }

    func onCloseClicked(context: CTTemplateContext) {
        let campaignKey = context.string(name: "digia_campaign_key")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? context.name()
        CleverTapTemplateRegistration.invalidate(context: context, campaignKey: campaignKey)
    }
}
