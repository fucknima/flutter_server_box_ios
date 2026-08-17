import Foundation

enum AppGroup {
    static let id = "group.tech.lolli.serverbox.native"
    static let watchURLsKey = "native.watch.urls"
    static let pushTokenKey = "native.push.token"

    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: id)
    }
}
