@testable import DigiaEngage
@testable import DigiaEngageCleverTap
import Foundation
import Testing

/// The plugin-owned pending buffer (#71): CleverTap payloads wait while Core is not ready.
@MainActor
@Suite("DigiaCleverTapPlugin — pending buffer", .serialized)
struct CleverTapPendingBufferTests {

    private let client = FakeCleverTapClient()
    private let host = FakeCEPHost()
    private let plugin: DigiaCleverTapPlugin

    init() {
        plugin = DigiaCleverTapPlugin(client: client)
        host.isReady = false
        plugin.attach(host: host)
    }

    @Test("a template is buffered, not settled, and flushes on onHostReady")
    func templateFlushesOnReady() {
        let handle = FakeTemplateHandle()
        plugin.onTemplatePresented(handle)
        #expect(host.delivered.isEmpty)
        #expect(handle.dismissedCount == 0, "the CleverTap slot is held, not released")

        host.isReady = true
        plugin.onHostReady()
        #expect(host.delivered.map(\.campaignKey) == ["onboarding_tip"])
        #expect(handle.dismissedCount == 0, "accepted, so still held")
    }

    @Test("templates flush newest first")
    func templatesNewestFirst() {
        let older = FakeTemplateHandle(campaignKey: "older")
        plugin.onTemplatePresented(older)
        plugin.onTemplatePresented(FakeTemplateHandle(campaignKey: "newer"))
        host.isReady = true
        plugin.onHostReady()
        #expect(host.delivered.map(\.campaignKey) == ["newer", "older"])
        #expect(older.dismissedCount == 0)
    }

    @Test("a not_ready outcome puts the template back in the buffer without setDismissed")
    func notReadyRebuffers() {
        host.isReady = true
        host.syncDrop = .notReady
        let handle = FakeTemplateHandle()
        plugin.onTemplatePresented(handle)
        #expect(host.delivered.count == 1)
        #expect(handle.dismissedCount == 0)

        host.syncDrop = nil
        plugin.onHostReady()
        #expect(host.delivered.count == 2)
        #expect(handle.dismissedCount == 0)
    }

    @Test("FAILED drops buffered templates with setDismissed, and later ones go to deliver")
    func failedDropsAndStopsBuffering() {
        let handle = FakeTemplateHandle()
        plugin.onTemplatePresented(handle)
        plugin.onHostInitFailed()
        #expect(handle.dismissedCount == 1)
        #expect(host.delivered.isEmpty)

        host.syncDrop = .initializationFailed
        let later = FakeTemplateHandle()
        plugin.onTemplatePresented(later)
        #expect(host.delivered.count == 1)
        #expect(later.dismissedCount == 1, "dropped by Core and settled with CleverTap at once")
    }

    @Test("detach settles buffered templates")
    func detachSettlesBuffered() {
        let handle = FakeTemplateHandle()
        plugin.onTemplatePresented(handle)
        plugin.detach()
        #expect(handle.dismissedCount == 1)
    }

    @Test("Native Display flushes in arrival order with one copy per unit id")
    func nativeDisplayInlineOrder() {
        client.emitDisplayUnits([displayUnit("u1", campaignKey: "a"), displayUnit("u2", campaignKey: "b")])
        client.emitDisplayUnits([displayUnit("u1", campaignKey: "a2")])
        #expect(host.delivered.isEmpty)

        host.isReady = true
        plugin.onHostReady()
        #expect(host.delivered.map(\.cepCampaignId) == ["u2", "u1"])
        #expect(host.delivered.last?.campaignKey == "a2")
    }

    @Test("a not_ready Native Display delivery is buffered again")
    func nativeDisplayRebuffers() {
        host.isReady = true
        host.syncDrop = .notReady
        client.emitDisplayUnits([displayUnit("u1", campaignKey: "a")])
        host.syncDrop = nil
        plugin.onHostReady()
        #expect(host.delivered.map(\.cepCampaignId) == ["u1", "u1"])
    }

    @Test("superseded drop from pending buffer reaches HealthSink with cep = clevertap")
    func supersededDropReachesHealthSink() {
        let healthSink = HealthSink()
        let recorder = HealthRecorder()
        healthSink.activate(recorder.record)
        defer { healthSink.resetForTest() }

        var handles: [FakeTemplateHandle] = []
        for i in 1...20 {
            let handle = FakeTemplateHandle(campaignKey: "cmp_\(i)")
            handles.append(handle)
            plugin.onTemplatePresented(handle)
        }
        #expect(recorder.payloads.isEmpty)
        #expect(handles.allSatisfy { $0.dismissedCount == 0 })

        // 21st template exceeds capacity (20), dropping the oldest (cmp_1) as superseded.
        let handle21 = FakeTemplateHandle(campaignKey: "cmp_21")
        plugin.onTemplatePresented(handle21)

        #expect(handles[0].dismissedCount == 1, "oldest template freed on drop")
        #expect(recorder.payloads.count == 1)
        let drop = recorder.payloads.first
        #expect(drop?.reason == "superseded")
        #expect(drop?.campaignKey == "cmp_1")
        #expect(drop?.detail?["cep"] == "clevertap")
    }
}

private final class HealthRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [HealthEventPayload] = []

    var payloads: [HealthEventPayload] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func record(_ payload: HealthEventPayload) {
        lock.lock()
        stored.append(payload)
        lock.unlock()
    }
}

