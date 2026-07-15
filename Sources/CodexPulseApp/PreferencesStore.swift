import Foundation
import CodexPulseCore

@MainActor
final class PreferencesStore {
    private enum Key {
        static let dynamicIcon = "dynamicIconEnabled"
        static let launchWithCodex = "launchWithCodex"
        static let pinnedSession = "pinnedSessionID"
        static let codexHome = "codexHomePath"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Key.launchWithCodex) == nil {
            defaults.set(true, forKey: Key.launchWithCodex)
        }
    }

    var value: PulsePreferences {
        PulsePreferences(
            dynamicIconEnabled: defaults.bool(forKey: Key.dynamicIcon),
            launchWithCodex: defaults.bool(forKey: Key.launchWithCodex),
            pinnedSessionID: defaults.string(forKey: Key.pinnedSession)
        )
    }

    var codexHome: URL {
        if let path = defaults.string(forKey: Key.codexHome), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }

    func setDynamicIcon(_ enabled: Bool) {
        defaults.set(enabled, forKey: Key.dynamicIcon)
    }

    func setLaunchWithCodex(_ enabled: Bool) {
        defaults.set(enabled, forKey: Key.launchWithCodex)
    }

    func setPinnedSession(_ id: String?) {
        if let id { defaults.set(id, forKey: Key.pinnedSession) }
        else { defaults.removeObject(forKey: Key.pinnedSession) }
    }

    func setCodexHome(_ url: URL) {
        defaults.set(url.standardizedFileURL.path, forKey: Key.codexHome)
    }
}
