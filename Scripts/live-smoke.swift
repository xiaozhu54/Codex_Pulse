import Foundation
import CodexPulseCore

let home = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".codex", isDirectory: true)
let engine = CodexPulseEngine(codexHome: home)

do {
    let state = try engine.refresh(PulseRefreshRequest(codexRunning: true, pinnedSessionID: nil))
    let snapshot = state.snapshot
    print("visibility=\(snapshot.visibility)")
    print("weekly=\(snapshot.weeklyRemainingPercent.map { String(format: "%.1f", $0) } ?? "unavailable")")
    print("speedKind=\(snapshot.tokenSpeed.kind)")
    print("model=\(snapshot.model.value ?? "unavailable")")
    print("context=\(snapshot.contextAvailablePercent.map { String(format: "%.1f", $0) } ?? "unavailable")")
    print("eligibleSessions=\(state.sessions.count)")
} catch {
    print("live-smoke-error=\(String(describing: error))")
    exit(1)
}
