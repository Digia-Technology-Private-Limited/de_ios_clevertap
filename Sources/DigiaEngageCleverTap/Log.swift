import Foundation
import DigiaEngage

/// Diagnostic logging for the CleverTap plugin.
enum Log {
    private static let log = DigiaLogger("CT")

    static func info(_ message: @autoclosure @escaping () -> String, campaign: String? = nil) {
        log.i(message(), campaign: campaign)
    }

    static func warn(
        _ message: @autoclosure @escaping () -> String,
        campaign: String? = nil,
        stage: TimelineStage? = nil,
        reason: DiagnosticReason? = nil
    ) {
        log.w(message(), campaign: campaign, stage: stage, reason: reason)
    }

    static func error(_ message: @autoclosure @escaping () -> String, campaign: String? = nil) {
        log.e(message(), campaign: campaign)
    }

    static func debug(_ message: @autoclosure @escaping () -> String, campaign: String? = nil) {
        log.d(message(), campaign: campaign)
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
