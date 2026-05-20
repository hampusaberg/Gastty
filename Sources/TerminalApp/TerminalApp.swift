import SwiftUI

@main
struct TerminalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Window/tab lifecycle is owned by AppDelegate so we don't expose
        // a SwiftUI WindowGroup. The Settings scene is the no-op anchor
        // SwiftUI needs to satisfy the Scene requirement.
        Settings { EmptyView() }
    }
}
