import SwiftUI

@main
struct Jpg2HeifApp: App {
    var body: some Scene {
        WindowGroup("to HEIF") {
            ContentView()
        }
        .windowResizability(.contentMinSize)
    }
}
