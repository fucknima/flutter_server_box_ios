import SwiftUI

@main
struct ServerBoxApp: App {
    @StateObject private var viewModel = ServerListViewModel()

    var body: some Scene {
        WindowGroup {
            RootView(viewModel: viewModel)
        }
    }
}
