import DigiaEngage
import Foundation

final class CleverTapPayloadMapper {

    private static let campaignKeyNames: [String] = [
        "digiaKey", "digia_key", "digia-key",
        "campaignKey", "campaign_key", "campaign-key",
        "digiaCampaign", "digia_campaign", "digia-campaign",
        "digiaCampaignKey", "digia_campaign_key", "digia-campaign-key",
    ]

    private static let reservedKvKeys: Set<String> = Set(campaignKeyNames).union([
        "$variables", "variables",
        "id", "wzrk_id", "msg_id", "campaignId", "templateName",
    ])

    func map(_ data: [String: Any]) -> [CEPTriggerPayload] {
        let campaignId = stringValue(data["id"] ?? data["wzrk_id"] ?? data["msg_id"] ?? data["campaignId"])
        guard let campaignId, !campaignId.isEmpty else { return [] }

        let templateName = stringValue(data["templateName"]) ?? CleverTapTemplateRegistration.templateName

        guard let campaignKey = extractCampaignKey(from: data) else { return [] }

        let variables = parseKvVariables(data)
        return [
            CEPTriggerPayload(
                cepCampaignId: campaignId,
                campaignKey: campaignKey,
                cepMetadata: ["templateName": templateName],
                variables: variables?.isEmpty == false ? variables : nil
            ),
        ]
    }

    private func extractCampaignKey(from data: [String: Any]) -> String? {
        for name in Self.campaignKeyNames {
            if let value = stringValue(data[name]) { return value }
        }
        return nil
    }

    private func parseKvVariables(_ data: [String: Any]) -> [String: String]? {
        var vars: [String: String] = [:]

        if let rawVars = data["$variables"] ?? data["variables"] {
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

        for (k, v) in data {
            if Self.reservedKvKeys.contains(k) || k.hasPrefix("wzrk_") { continue }
            if let s = v as? String { vars[k] = s }
            else if let n = v as? NSNumber { vars[k] = n.stringValue }
        }

        return vars.isEmpty ? nil : vars
    }

    private func stringValue(_ raw: Any?) -> String? {
        guard let raw else { return nil }
        let value = (raw as? String ?? String(describing: raw)).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
