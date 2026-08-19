import SwiftUI
import AppUI

/// The application entry point, and nothing more.
///
/// Everything the app actually does lives in `PencilLoopKit` — this target
/// exists so there is something to sign and install. Keeping the shell empty is
/// what lets `swift build` be a complete compile check of the real code.
///
/// The one thing it owns is the shell's state: `RootModel` is made here, once,
/// so that it outlives every view update the scene makes. It builds
/// `LiveEnvironment` — the composition root, in `AppUI/Support` — on its first
/// `start()`, resolves the sync folder if there is one, and shows first run when
/// there is not.
@main
struct PencilLoopApp: App {

    @State private var model = RootModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
    }
}
