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

        // digiaKey-only payload: routes through the campaign store for native carousel rendering
        let digiaKey = stringValue(data["digiaKey"])
        if let digiaKey, placementKey == nil, viewId == nil {
            payloads.append(
                InAppPayload(
                    id: campaignId,
                    content: InAppPayloadContent(
                        type: "inline",
                        placementKey: digiaKey,
                        args: args
                    ),
                    cepContext: ["templateName": templateName]
                )
            )
        }

        return payloads
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
