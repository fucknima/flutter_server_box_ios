import SwiftUI

@main
struct ServerBoxApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = ServerListViewModel()

    var body: some Scene {
        WindowGroup {
            AppShellView(serverViewModel: viewModel)
        }
    }
}
