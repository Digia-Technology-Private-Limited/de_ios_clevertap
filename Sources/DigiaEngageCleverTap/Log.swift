import Foundation
import os

/// Diagnostic logging for the CleverTap plugin.
///
/// Traces why a campaign did or did not render — presented → key parsed →
/// delivered → accepted/declined → displayed → settled → slot released —
/// alongside CleverTap's own logs. This trace is the first thing to reach for
/// when a customer reports "my in-apps stopped appearing", because that stall is
/// almost always a slot that was taken and never released.
///
/// ``info(_:)`` is verbose and compiled out of release builds. ``warn(_:)`` and
/// ``error(_:)`` always emit: the conditions they report (a stalled slot, a
/// failed dismiss) are exactly what a production bug report needs, and are rare
/// enough not to be noisy.
enum Log {
    private static let logger = Logger(subsystem: "tech.digia.engage", category: "CleverTap")

    static func info(_ message: @autoclosure @escaping () -> String) {
        #if DEBUG
        logger.debug("\(message(), privacy: .public)")
        #endif
    }

    static func warn(_ message: @autoclosure @escaping () -> String) {
        logger.warning("\(message(), privacy: .public)")
    }

    static func error(_ message: @autoclosure @escaping () -> String) {
        logger.error("\(message(), privacy: .public)")
    }
}

/// Runs `work` on the main actor, inline when the caller is already there.
///
/// CleverTap presents in-apps on the main thread, and the slot's release path
/// depends on running synchronously inside `setDismissed()` so the next queued
/// in-app can re-enter the presenter. An unconditional `DispatchQueue.main.async`
/// would break that ordering, so the hop only happens when it is genuinely
/// needed.
func onMainActor(_ work: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated(work)
    } else {
        DispatchQueue.main.async { MainActor.assumeIsolated(work) }
    }
}
