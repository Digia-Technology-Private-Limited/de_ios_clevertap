import DigiaEngage
import Foundation

/// Turns CleverTap campaign data into Digia `CEPTriggerPayload`s.
///
/// CleverTap reaches Digia through two channels that share nothing but this
/// mapper, so each gets its own entry point:
///
/// | Channel | Entry point | Holds the in-app slot? |
/// |---|---|---|
/// | Custom template (`DigiaTemplate`) | ``mapTemplate(_:)`` | yes |
/// | Native Display (Display Units) | ``mapDisplayUnits(_:)`` | no |
///
/// Keeping them separate is what lets the Native Display path carry a
/// `displayUnitId` through `cepMetadata` — the id the plugin later needs to
/// report views and clicks back to CleverTap, which CleverTap never infers on its
/// own (`docs-internal/cep-integrations/clevertap.md` §12.8).
///
/// Pure and side-effect free: every branch is unit-coverable with fixtures.
struct CleverTapPayloadMapper: Sendable {

    static let metadataTemplateName = "templateName"
    static let metadataCampaignId = "campaignId"

    /// Marks a trigger as Native Display. Its presence selects the tracking path.
    static let metadataDisplayUnitId = "displayUnitId"

    /// The older spelling of `CleverTapTemplates.argVariables`.
    private static let argsKey = "args"
    private static let wzrkPrefix = "wzrk_"

    /// Accepted spellings of the campaign key in a Display Unit's key-values.
    ///
    /// Dashboard authors type this by hand, so every plausible casing and
    /// separator is accepted rather than silently dropping the campaign. The
    /// custom-template path needs no aliases — its argument name is fixed by the
    /// template definition.
    static let campaignKeyNames = [
        "digiaKey", "digia_key", "digia-key",
        "campaignKey", "campaign_key", "campaign-key",
        "digiaCampaign", "digia_campaign", "digia-campaign",
        "digiaCampaignKey", "digia_campaign_key", "digia-campaign-key",
    ]

    private static let reservedKvKeys: Set<String> = Set(campaignKeyNames).union([
        CleverTapTemplates.argVariables,
        argsKey,
        "id", "wzrk_id", "msg_id", "campaignId", metadataTemplateName,
    ])

    // MARK: - Custom template

    /// Reads a live `DigiaTemplate` invocation.
    ///
    /// - Returns: the trigger, or `nil` when the template carries no usable
    ///   campaign key — the caller must then free the slot rather than deliver
    ///   nothing.
    @MainActor
    func mapTemplate(_ handle: TemplateHandle) -> CEPTriggerPayload? {
        let campaignKey = handle
            .string(named: CleverTapTemplates.argCampaignKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !campaignKey.isEmpty else { return nil }

        let rawVariables = handle.string(named: CleverTapTemplates.argVariables)
        let variables = rawVariables.map(parseVariableBlob) ?? [:]

        return CEPTriggerPayload(
            // The template channel has no per-invocation id of its own, so the
            // campaign key stands in. Internal identity is CampaignPresentation.id
            // precisely because this field collides across re-triggers.
            cepCampaignId: campaignKey,
            campaignKey: campaignKey,
            cepMetadata: [Self.metadataTemplateName: handle.templateName],
            variables: variables.isEmpty ? nil : variables
        )
    }

    // MARK: - Native Display

    /// Maps a batch of Native Display units.
    ///
    /// Units without a unit id or without a recognised campaign key are skipped:
    /// Native Display batches routinely contain campaigns that belong to the host
    /// app rather than to Digia.
    func mapDisplayUnits(_ units: [DisplayUnit]) -> [CEPTriggerPayload] {
        units.compactMap { unit in
            let unitId = unit.unitId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !unitId.isEmpty,
                  let campaignKey = extractCampaignKey(unit.customKeyValues)
            else { return nil }

            let variables = parseKvVariables(unit.customKeyValues)
            return CEPTriggerPayload(
                cepCampaignId: unitId,
                campaignKey: campaignKey,
                cepMetadata: [
                    Self.metadataCampaignId: unitId,
                    // The plugin keys view/click reporting off this, and uses its
                    // presence to tell the two channels apart.
                    Self.metadataDisplayUnitId: unitId,
                ],
                variables: variables.isEmpty ? nil : variables
            )
        }
    }

    // MARK: - Helpers

    private func extractCampaignKey(_ keyValues: [String: String]) -> String? {
        for name in Self.campaignKeyNames {
            let value = keyValues[name]?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value, !value.isEmpty { return value }
        }
        return nil
    }

    /// Parses the `variables` / `args` blob into flat string variables.
    ///
    /// Strict JSON first. The lenient fallback exists because CleverTap profile
    /// expressions can interpolate unquoted values into the blob
    /// (`{"name": Priya}`), which is not valid JSON but is a real payload a live
    /// campaign produces. Losing every variable because one was unquoted would
    /// render the campaign with raw placeholders in front of a real user, so
    /// lenient extraction wins here.
    func parseVariableBlob(_ raw: String) -> [String: String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "{}" else { return [:] }

        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var result: [String: String] = [:]
            for (key, value) in object {
                if let stringValue = Self.stringify(value) { result[key] = stringValue }
            }
            return result
        }

        return Self.lenientEntries(in: trimmed)
    }

    /// Builds display-unit variables from the blob plus the unit's own flat
    /// key-values, so a campaign author can set a variable either way.
    private func parseKvVariables(_ keyValues: [String: String]) -> [String: String] {
        var variables: [String: String] = [:]

        if let blob = keyValues[CleverTapTemplates.argVariables] ?? keyValues[Self.argsKey] {
            variables = parseVariableBlob(blob)
        }

        for (key, value) in keyValues {
            // `wzrk_*` is CleverTap's own reserved namespace, never campaign data.
            guard !Self.reservedKvKeys.contains(key), !key.hasPrefix(Self.wzrkPrefix), !value.isEmpty
            else { continue }
            variables[key] = value
        }
        return variables
    }

    private static func stringify(_ value: Any) -> String? {
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

    /// `"key": "value"` or `"key": bareValue` — the lenient fallback.
    private static let unquotedEntry = try? NSRegularExpression(
        pattern: "\"([A-Za-z_][A-Za-z0-9_]*)\"\\s*:\\s*(?:\"((?:[^\"\\\\]|\\\\.)*)\"|([^,}]+))"
    )

    private static func lenientEntries(in raw: String) -> [String: String] {
        guard let regex = unquotedEntry else { return [:] }
        var result: [String: String] = [:]
        let range = NSRange(raw.startIndex..., in: raw)

        for match in regex.matches(in: raw, range: range) {
            guard let keyRange = Range(match.range(at: 1), in: raw) else { continue }
            let key = String(raw[keyRange])

            let valueRange = Range(match.range(at: 2), in: raw) ?? Range(match.range(at: 3), in: raw)
            guard let valueRange else { continue }
            let value = String(raw[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)

            if !key.isEmpty, !value.isEmpty { result[key] = value }
        }
        return result
    }
}
