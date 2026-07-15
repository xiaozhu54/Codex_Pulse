import Foundation
import CodexPulseCore

let home = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".codex", isDirectory: true)
let engine = CodexPulseEngine(codexHome: home)

do {
    let snapshot = try engine.snapshot(codexRunning: true, preferences: PulsePreferences())
    let sessions = try engine.availableSessions()
    print("visibility=\(snapshot.visibility)")
    print("weekly=\(snapshot.weeklyRemainingPercent.map { String(format: "%.1f", $0) } ?? "unavailable")")
    print("speedKind=\(snapshot.tokenSpeed.kind)")
    print("model=\(snapshot.model ?? "unavailable")")
    print("context=\(snapshot.contextAvailablePercent.map { String(format: "%.1f", $0) } ?? "unavailable")")
    print("eligibleSessions=\(sessions.count)")
} catch {
    print("live-smoke-error=\(String(describing: error))")
    exit(1)
}
