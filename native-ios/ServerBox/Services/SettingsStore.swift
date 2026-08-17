import Foundation

enum SettingsStore {
    static let timeOutKey = "native.timeOut"
    static let recordHistoryKey = "native.recordHistory"
    static let textFactorKey = "native.textFactor"
    static let virtKeyOrderKey = "native.term.virtKeyOrder"
    static let virtKeyDisabledKey = "native.term.virtKeyDisabled"
    static let pushTokenKey = "native.push.token"
    static let watchURLsKey = "native.watch.urls"

    private static let defaults = UserDefaults.standard

    static var timeOut: Int {
        get {
            let stored = defaults.integer(forKey: timeOutKey)
            return stored > 0 ? stored : 5
        }
        set { defaults.set(max(1, newValue), forKey: timeOutKey) }
    }

    static var recordHistory: Bool {
        get {
            defaults.object(forKey: recordHistoryKey) == nil
                ? true
                : defaults.bool(forKey: recordHistoryKey)
        }
        set { defaults.set(newValue, forKey: recordHistoryKey) }
    }

    static var textFactor: Double {
        get {
            let stored = defaults.double(forKey: textFactorKey)
            return stored > 0 ? stored : 1.0
        }
        set { defaults.set(max(0.5, min(3.0, newValue)), forKey: textFactorKey) }
    }

    static var virtKeyOrder: [String] {
        get { defaults.stringArray(forKey: virtKeyOrderKey) ?? [] }
        set { defaults.set(newValue, forKey: virtKeyOrderKey) }
    }

    static var virtKeyDisabled: Set<String> {
        get { Set(defaults.stringArray(forKey: virtKeyDisabledKey) ?? []) }
        set { defaults.set(Array(newValue), forKey: virtKeyDisabledKey) }
    }

    static let editableKeys: [String] = [
        timeOutKey,
        recordHistoryKey,
        textFactorKey,
        virtKeyOrderKey,
        virtKeyDisabledKey,
    ]
}

enum HiddenSettingHelp {
    static let descriptions: [String: String] = [
        SettingsStore.timeOutKey: "Connection timeout for servers, etc. (seconds). Default: 5",
        SettingsStore.recordHistoryKey: "Whether to save and use history records (SFTP paths, etc.). Default: true",
        SettingsStore.textFactorKey: "Text scaling factor (double). Default: 1.0 (100%)",
        SettingsStore.virtKeyOrderKey: "SSH virtual key order as an array of key names.",
        SettingsStore.virtKeyDisabledKey: "SSH virtual keys that are disabled, as an array of key names.",
    ]
}
