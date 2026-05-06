import SwiftUI

@main
struct FramewiseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup(id: "comparison") {
            ContentView()
        }
        .defaultSize(width: 1600, height: 1000)
        .commands {
            CommandGroup(replacing: .newItem) {
                NewWindowButton()
            }
        }
    }
}

private struct NewWindowButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New Window") {
            openWindow(id: "comparison")
        }
        .keyboardShortcut("n", modifiers: .command)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Files opened from Finder ("Open With Framewise"), the Dock, or
    /// `open` on the command line route through here. SwiftUI's WindowGroup
    /// will spin up a window if needed; the URLRouter buffers files until a
    /// `MediaEngine` is registered to receive them.
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            URLRouter.shared.deliver(urls: urls)
        }
    }
}

/// Routes incoming file URLs (from `application(_:open:)`) to a `MediaEngine`.
///
/// Two timing cases need to be handled:
///   1. App is cold-launched with files → `application(_:open:)` may run
///      before any `ContentView` exists. Buffer URLs until the first engine
///      registers, then deliver as a batch.
///   2. App is already running → the most-recently-active engine receives
///      the files and uses `loadMediaBatch` to fill A and B.
@MainActor
final class URLRouter {
    static let shared = URLRouter()

    private weak var activeEngine: MediaEngine?
    private var pendingURLs: [URL] = []

    func deliver(urls: [URL]) {
        if let engine = activeEngine {
            engine.loadMediaBatch(urls: urls)
        } else {
            pendingURLs.append(contentsOf: urls)
        }
    }

    /// Called by each `ContentView` when its engine becomes available. Most
    /// recent registration wins, so the front-most window receives subsequent
    /// file opens.
    func register(engine: MediaEngine) {
        activeEngine = engine
        if !pendingURLs.isEmpty {
            let queued = pendingURLs
            pendingURLs.removeAll()
            engine.loadMediaBatch(urls: queued)
        }
    }
}
