import SwiftUI

@main
struct NudgeMobileApp: App {
    @State private var model = AppModel.persistent()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}
