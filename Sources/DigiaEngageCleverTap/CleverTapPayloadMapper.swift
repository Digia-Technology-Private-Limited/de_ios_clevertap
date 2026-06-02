import DigiaEngage
import Foundation

final class CleverTapPayloadMapper {
    func map(_ data: [String: Any]) -> [InAppPayload] {
        let campaignId = stringValue(data["id"] ?? data["wzrk_id"] ?? data["msg_id"] ?? data["campaignId"])
        guard let campaignId, !campaignId.isEmpty else { return [] }

        let templateName = stringValue(data["templateName"]) ?? CleverTapTemplateRegistration.templateName
        let args = normalizeArgs(data["args"])
        let viewId = stringValue(data["viewId"])
        let command = stringValue(data["command"])
        let placementKey = stringValue(data["placementKey"])
        let anchorKey = stringValue(data["anchorKey"])
        var payloads: [InAppPayload] = []

        if let command, let viewId {
            let normalizedCommand = command.uppercased()
            let payloadId = anchorKey.map { "\(campaignId):\(normalizedCommand):\($0)" } ?? campaignId
            payloads.append(
                InAppPayload(
                    id: payloadId,
                    content: InAppPayloadContent(
                        type: presentationType(forCleverTapCommand: normalizedCommand),
                        viewId: viewId,
                        command: normalizedCommand,
                        args: args,
                        anchorKey: anchorKey
                    ),
                    cepContext: ["templateName": templateName]
                )
            )
        }

        if let placementKey, let viewId {
            payloads.append(
                InAppPayload(
                    id: "\(campaignId):\(placementKey)",
                    content: InAppPayloadContent(
                        type: "inline",
                        placementKey: placementKey,
                        viewId: viewId,
                        args: args
                    ),
                    cepContext: ["templateName": templateName]
                )
            )
        }

        // digia_campaign_key (primary) or legacy aliases — route through the campaign store.
        let campaignKey =
            stringValue(data["digia_campaign_key"])
            ?? stringValue(data["digiaKey"])
            ?? stringValue(data["campaign_key"])
            ?? stringValue(data["campaignKey"])
        if let campaignKey, placementKey == nil, viewId == nil {
            let variables = parseKvVariables(data)
            payloads.append(
                InAppPayload(
                    id: campaignId,
                    content: InAppPayloadContent(
                        type: "overlay",
                        campaignKey: campaignKey,
                        variables: variables?.isEmpty == false ? variables : nil
                    ),
                    cepContext: ["templateName": templateName]
                )
            )
        }

        return payloads
    }

    private static let reservedKvKeys: Set<String> = [
        "digia_campaign_key", "digiaKey", "campaign_key", "campaignKey",
        "$variables", "command", "viewId", "anchorKey", "placementKey",
        "screenId", "args", "id", "wzrk_id", "msg_id", "campaignId",
        "templateName",
    ]

    private func parseKvVariables(_ data: [String: Any]) -> [String: String]? {
        var vars: [String: String] = [:]
        // 1. Seed from $variables JSON blob (base map)
        if let rawVars = data["$variables"] {
            var parsed: [String: Any]?
            if let str = rawVars as? String,
               let jsonData = str.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                parsed = obj
            } else if let obj = rawVars as? [String: Any] {
                parsed = obj
            }
            if let parsed {
                for (k, v) in parsed {
                    if let s = v as? String { vars[k] = s }
                    else if let n = v as? NSNumber { vars[k] = n.stringValue }
                }
            }
        }
        // 2. Flat top-level keys override $variables on conflict
        for (k, v) in data {
            if Self.reservedKvKeys.contains(k) || k.hasPrefix("wzrk_") { continue }
            if let s = v as? String { vars[k] = s }
            else if let n = v as? NSNumber { vars[k] = n.stringValue }
        }
        return vars.isEmpty ? nil : vars
    }

    private func presentationType(forCleverTapCommand command: String) -> String {
        switch command {
        case "SHOW_BOTTOM_SHEET": return "bottomsheet"
        case "SHOW_DIALOG": return "dialog"
        default:
            if command.hasPrefix("SHOW_") {
                return String(command.dropFirst(5)).lowercased()
            }
            return command.lowercased()
        }
    }

    private func normalizeArgs(_ raw: Any?) -> [String: JSONValue] {
        if let object = raw as? [String: JSONValue] { return object }
        if let object = raw as? [String: Any] { return object.compactMapValues(jsonValue(from:)) }
        if let object = raw as? [AnyHashable: Any] {
            var result: [String: JSONValue] = [:]
            for (key, value) in object {
                guard let key = key as? String, let json = jsonValue(from: value) else { continue }
                result[key] = json
            }
            return result
        }
        if let rawString = stringValue(raw) {
            let data = Data(rawString.utf8)
            guard let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
                assertionFailure("CleverTap args must decode to an object.")
                return [:]
            }
            return decoded
        }
        return [:]
    }

    private func jsonValue(from value: Any) -> JSONValue? {
        switch value {
        case let json as JSONValue: return json
        case let string as String: return .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            if number.doubleValue.rounded(.towardZero) == number.doubleValue { return .int(number.intValue) }
            return .double(number.doubleValue)
        case let int as Int: return .int(int)
        case let double as Double: return .double(double)
        case let bool as Bool: return .bool(bool)
        case let dict as [String: Any]: return .object(dict.compactMapValues(jsonValue(from:)))
        case let dict as [AnyHashable: Any]:
            var result: [String: JSONValue] = [:]
            for (key, value) in dict {
                guard let key = key as? String, let json = jsonValue(from: value) else { continue }
                result[key] = json
            }
            return .object(result)
        case let array as [Any]: return .array(array.compactMap(jsonValue(from:)))
        case _ as NSNull: return .null
        default: return nil
        }
    }

    private func stringValue(_ raw: Any?) -> String? {
        guard let raw else { return nil }
        let value = (raw as? String ?? String(describing: raw)).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
