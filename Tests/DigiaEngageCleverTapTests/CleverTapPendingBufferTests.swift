@testable import DigiaEngage
@testable import DigiaEngageCleverTap
import Foundation
import Testing

/// The plugin-owned pending buffer (#71): CleverTap payloads wait while Core is not ready.
@MainActor
@Suite("DigiaCleverTapPlugin — pending buffer", .serialized)
struct CleverTapPendingBufferTests {

    private let clock = FakeClock()
    private let client = FakeCleverTapClient()
    private let host = FakeCEPHost()
    private let plugin: DigiaCleverTapPlugin

    init() {
        let clock = clock
        plugin = DigiaCleverTapPlugin(
            client: client, schedule: { clock.schedule($0, $1) }, now: { clock.now }
        )
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
        #expect(host.delivered.map(\.campaignKey) == ["newer"])
        #expect(older.dismissedCount == 1, "the older template frees the slot as surface_busy")
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

    @Test("a template held for 5 minutes expires and frees the slot")
    func templateExpires() {
        let handle = FakeTemplateHandle()
        plugin.onTemplatePresented(handle)
        clock.advance(299)
        #expect(handle.dismissedCount == 0)
        clock.advance(1)
        #expect(handle.dismissedCount == 1)
        #expect(host.delivered.isEmpty)
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
}
